"""Anonymous public Wegmans product evidence for Chantilly's in-store channel."""
import json
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from email.utils import parsedate_to_datetime

import httpx

from .adapters import AdapterContext, OfferEvidence

ENDPOINT = 'https://www.wegmans.com/api/products/133/{product}'
_PRODUCT_ID = re.compile(r'[0-9]{1,20}')
_SIZE = re.compile(r'(\d+(?:\.\d+)?)\s*(gallon|lb|oz|count|ct)\.?', re.I)


class WegmansAdapter:
    retailer = 'wegmans'

    def __init__(self, *, client: httpx.Client | None = None, transport=None):
        self._client, self._transport = client, transport

    def fetch(self, context: AdapterContext, product_ids: list[str], *, timeout: float) -> list[OfferEvidence]:
        if context.retailer != 'wegmans' or context.channel != 'in_store' or context.location_id != '133':
            raise ValueError('Wegmans requires Chantilly store 133 in-store context')
        if (not product_ids or len(product_ids) > 50 or isinstance(timeout, bool)
                or not 0 < timeout <= 30 or any(not isinstance(pid, str) or not _PRODUCT_ID.fullmatch(pid) for pid in product_ids)):
            raise ValueError('Invalid bounded Wegmans request')
        owned = self._client is None
        client = self._client or httpx.Client(transport=self._transport)
        records = []
        try:
            for product_id in dict.fromkeys(product_ids):
                response = client.get(ENDPOINT.format(product=product_id), timeout=timeout)
                response.raise_for_status()
                retrieved = datetime.now(timezone.utc)
                observed = self._observed(response, retrieved)
                product = response.json(parse_float=Decimal)
                if not isinstance(product, dict):
                    raise ValueError('Malformed Wegmans product')
                if (product.get('objectId') != f'133-{product_id}' or product.get('storeNumber') != '133'
                        or any(product.get(key) != product_id for key in ('skuId', 'productID', 'productId'))):
                    raise ValueError('Wegmans response product/store identity mismatch')
                name = product.get('productName')
                if not isinstance(name, str) or not name.strip():
                    raise ValueError('Missing Wegmans product name')
                # A missing in-store offer stays unknown. Delivery/loyalty are never fallbacks.
                price = product.get('price_inStore')
                if price is None or price == {}:
                    price = {}
                elif not isinstance(price, dict) or price.get('channelKey') != '133-Instore':
                    raise ValueError('Wegmans response price channel mismatch')
                flags = [product.get('isSoldAtStore'), product.get('isAvailable')]
                if any(flag is not None and not isinstance(flag, bool) for flag in flags):
                    raise ValueError('Malformed Wegmans availability')
                available = False if False in flags else True if all(flag is True for flag in flags) else None
                barcodes = product.get('upc')
                if barcodes is not None and (not isinstance(barcodes, list) or any(not isinstance(code, str) or not code.strip() for code in barcodes)):
                    raise ValueError('Wegmans UPCs must remain source strings')
                barcode = barcodes[0] if barcodes else None
                quantity, unit, kind = self._quantity(product, price)
                records.append(OfferEvidence(
                    source_record_id=f'133-{product_id}-Instore', retailer_product_id=product_id,
                    product_name=name, barcode=barcode, price=price.get('amount'),
                    quantity=quantity, unit=unit, quantity_kind=kind, pack_count=1,
                    form=self._form(product), channel='in_store', available=available,
                    seller='Wegmans', location_id='133', observed_at=observed,
                    retrieved_at=retrieved, source_url=str(response.url),
                    conditions=self._conditions(product, price),
                ))
            return records
        finally:
            if owned:
                client.close()

    @staticmethod
    def _quantity(product, price):
        sold_by_weight = product.get('isSoldByWeight')
        if sold_by_weight is not None and not isinstance(sold_by_weight, bool):
            raise ValueError('Malformed weight-sale flag')
        text = product.get('packSize')
        match = _SIZE.fullmatch(text.strip()) if isinstance(text, str) else None
        if sold_by_weight is True:
            approx = product.get('onlineApproxUnitWeight')
            if approx is not None and (isinstance(approx, bool) or not isinstance(approx, (int, Decimal)) or not Decimal(approx).is_finite() or approx < 0):
                raise ValueError('Malformed approximate purchase weight')
            # The source's 1 lb label is the billing basis, not the purchased pack.
            # Only the observed pound-billed contract supports its approximate total.
            unit_text = price.get('unitPrice')
            if (match and Decimal(match[1]) == 1 and match[2].lower() == 'lb'
                    and isinstance(unit_text, str) and re.fullmatch(r'\$\d+(?:\.\d+)?/lb\.?', unit_text)
                    and approx is not None and approx > 0):
                return Decimal(approx), 'lb', 'estimated'
            return None, None, 'variable'
        if sold_by_weight is not False or not match:
            return None, None, 'variable'
        unit = {'gallon': 'fl_oz', 'count': 'each', 'ct': 'each'}.get(match[2].lower(), match[2].lower())
        value = Decimal(match[1]) * (128 if unit == 'fl_oz' else 1)
        if value <= 0:
            return None, None, 'variable'
        return value, unit, 'fixed'

    @staticmethod
    def _form(product):
        categories = product.get('category')
        if not categories:
            return 'Catalog form unspecified'
        if (not isinstance(categories, list) or not isinstance(categories[0], dict)
                or not isinstance(categories[0].get('name'), str) or not categories[0]['name'].strip()):
            raise ValueError('Malformed catalog category')
        # Category is explicit evidence, not a claimed frozen/fresh product form.
        return f"Catalog category: {categories[0]['name']}"

    @staticmethod
    def _conditions(product, price):
        if product.get('soldByVendor') is not None:
            raise ValueError('Unsupported vendor sale')
        terms = []
        deposit = product.get('bottleDeposit')
        if deposit is not None:
            if isinstance(deposit, bool) or not isinstance(deposit, (int, Decimal)) or not Decimal(deposit).is_finite() or deposit < 0:
                raise ValueError('Malformed bottle deposit')
            if deposit:
                terms.append(f'Source bottleDeposit {deposit}; deposit units and final cost unverified.')
        loyalty = product.get('price_inStoreLoyalty')
        discounts = product.get('loyaltyInstoreDiscount')
        coupons = product.get('digitalCouponsOfferIds')
        offers = product.get('digitalCouponsOffers')
        discount_type = product.get('discountType')
        if loyalty is not None and not isinstance(loyalty, dict):
            raise ValueError('Malformed loyalty price')
        if discount_type is not None and not isinstance(discount_type, str):
            raise ValueError('Malformed discount type')
        if discounts is not None and (not isinstance(discounts, list) or len(discounts) > 10 or any(not isinstance(item, dict) for item in discounts)):
            raise ValueError('Malformed loyalty terms')
        if coupons is not None and (not isinstance(coupons, list) or len(coupons) > 50 or any(not isinstance(code, str) for code in coupons)):
            raise ValueError('Malformed coupon identities')
        if offers is not None and (not isinstance(offers, list) or len(offers) > 50 or any(not isinstance(item, dict) for item in offers)):
            raise ValueError('Malformed coupon terms')
        if loyalty or discounts or coupons or offers or discount_type:
            terms.append('Base in-store price shown; loyalty/coupon eligibility and terms are unverified.')
            if loyalty:
                if loyalty.get('channelKey') != '133-Instore-Loyalty':
                    raise ValueError('Mismatched loyalty channel')
                terms.append('Conditional loyalty price ' + json.dumps({key: loyalty.get(key) for key in ('amount', 'unitPrice', 'fulfillmentPrice')}, default=str, sort_keys=True) + '.')
            if discount_type:
                terms.append(f'Source discountType: {discount_type}.')
            if discounts:
                fields = ('savings', 'expiryDate', 'triggerQuantity', 'discountedQuantity', 'discountPercent', 'cartLimit', 'name', 'description')
                terms.append('Source loyalty terms ' + json.dumps([{key: item.get(key) for key in fields if key in item} for item in discounts], default=str, sort_keys=True) + '.')
            if coupons:
                terms.append('Source coupon IDs: ' + ', '.join(coupons) + '; details may be missing.')
            if offers:
                # This version does not interpret the coupon schema or apply it.
                terms.append('Additional coupon offers present; quantities, validity and eligibility unresolved.')
        if product.get('isSoldByWeight') is True:
            terms.append(f"Estimated-weight package total; source unit price {price.get('unitPrice')!s}, fulfillmentPrice {price.get('fulfillmentPrice')!s}; actual weight/cost may vary.")
        return ' '.join(terms)

    @staticmethod
    def _observed(response, retrieved):
        date = response.headers.get('date')
        base = parsedate_to_datetime(date) if date else retrieved
        if base.tzinfo is None or base.utcoffset() is None:
            raise ValueError('Source Date requires a timezone')
        base = base.astimezone(timezone.utc)
        age = response.headers.get('age', '0')
        if not age.isdigit() or base > retrieved:
            raise ValueError('Invalid Wegmans cache metadata')
        return min(base, retrieved - timedelta(seconds=int(age)))
