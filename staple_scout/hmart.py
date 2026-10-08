"""Public VTEX catalog evidence. Never Centreville shelf or pickup prices."""
import re
from datetime import datetime, timedelta, timezone
from decimal import Decimal
from email.utils import parsedate_to_datetime

import httpx

from .adapters import AdapterContext, OfferEvidence
from .comparison import BASE_FACTORS, UNITS

ENDPOINT = 'https://www.hmart.com/api/catalog_system/pub/products/search/'
_SIZE = re.compile(r'(?<![\w.\-])(?P<value>\d+(?:\.\d+)?)\s*(?P<unit>fl\s*oz|oz|lbs?|kg|g|ml|l|count|ct|each)\b', re.I)
_COMPOSITE = re.compile(r'^(\d+):(\d+)$')


class HMartAdapter:
    retailer = 'hmart'

    def __init__(self, *, client: httpx.Client | None = None, transport=None):
        self._client, self._transport = client, transport

    def fetch(self, context: AdapterContext, product_ids: list[str], *, timeout: float) -> list[OfferEvidence]:
        if context.retailer != 'hmart' or context.channel != 'online' or context.location_id is not None:
            raise ValueError('H Mart catalog requires an online context with no local location ID')
        if len(product_ids) > 50 or not 0 < timeout <= 30:
            raise ValueError('Request exceeds source bounds')
        targets = {}
        for identity in product_ids:
            match = _COMPOSITE.fullmatch(identity)
            if not match:
                raise ValueError('Select an explicit H Mart productId:itemId identity')
            targets.setdefault(match[1], set()).add(match[2])
        owned = self._client is None
        client = self._client or httpx.Client(transport=self._transport)
        records = []
        try:
            for product_id, item_ids in targets.items():
                response = client.get(ENDPOINT, params={'fq': f'productId:{product_id}', '_from': 0, '_to': 49}, timeout=timeout)
                response.raise_for_status()
                retrieved = datetime.now(timezone.utc)
                observed = self._observed_time(response, retrieved)
                payload = response.json(parse_float=Decimal)
                # The live endpoint is a JSON array; fixtures may wrap the sanitized subset.
                products = payload if isinstance(payload, list) else payload.get('products')
                if not isinstance(products, list) or len(products) > 50:
                    raise ValueError('Malformed catalog response')
                for product in products:
                    if str(product.get('productId')) != product_id:
                        raise ValueError('Catalog response returned a different product')
                    for item in product['items']:
                        item_id = item.get('itemId')
                        if item_id not in item_ids:
                            continue
                        sellers = [seller for seller in item['sellers']
                                   if seller.get('sellerId') == '1' and seller.get('sellerName') == 'HMart - US']
                        if not sellers:
                            continue  # Missing permitted seller is a coverage gap, not a cheap alternative.
                        if len(sellers) != 1:
                            raise ValueError('Ambiguous first-party offer')
                        offer = sellers[0]['commertialOffer']
                        name = item.get('name') or product.get('productName')
                        if not isinstance(name, str) or not name.strip():
                            raise ValueError('Missing product name')
                        barcode = item.get('ean') or None
                        if barcode is not None and not isinstance(barcode, str):
                            raise ValueError('Barcode must be source text')
                        quantity, unit = self._quantity(name)
                        # This first integration supports only ordinary single purchase units.
                        if item.get('isKit') or (item.get('unitMultiplier', Decimal('1')) != Decimal('1')):
                            quantity, unit = None, None
                        available = offer.get('IsAvailable')
                        stock = offer.get('AvailableQuantity')
                        if stock is not None:
                            if isinstance(stock, bool) or not isinstance(stock, (int, Decimal)) or stock < 0:
                                raise ValueError('Malformed online stock')
                            if stock == 0:
                                available = False
                        list_price = offer.get('ListPrice')
                        if list_price is not None and (isinstance(list_price, bool) or not isinstance(list_price, (int, Decimal)) or not Decimal(list_price).is_finite() or list_price < 0):
                            raise ValueError('Malformed online list price')
                        terms = 'Online catalog reference; Centreville stock, shipping and promotion eligibility are unverified.'
                        if offer.get('ListPrice') is not None and offer.get('Price') is not None and offer['ListPrice'] != offer['Price']:
                            terms += f" Source ListPrice USD {offer['ListPrice']}; discount terms are unverified."
                        storage = product.get('Refrigerated') or ['Unspecified']
                        if not isinstance(storage, list) or len(storage) != 1 or not isinstance(storage[0], str):
                            raise ValueError('Malformed catalog storage form')
                        identity = f'{product_id}:{item_id}'
                        records.append(OfferEvidence(
                            source_record_id=identity, retailer_product_id=identity,
                            product_name=name, barcode=barcode, price=offer.get('Price'),
                            quantity=quantity, unit=unit, form=f'Catalog storage: {storage[0]}', channel='online',
                            available=available, seller='HMart - US', location_id=None,
                            observed_at=observed, retrieved_at=retrieved,
                            source_url=str(response.url), conditions=terms,
                            valid_until=self._timestamp(offer.get('PriceValidUntil')),
                        ))
            return records
        finally:
            if owned:
                client.close()

    @staticmethod
    def _observed_time(response, retrieved):
        date = response.headers.get('date')
        base = parsedate_to_datetime(date) if date else retrieved
        if base.tzinfo is None:
            raise ValueError('Source response date requires a timezone')
        base = base.astimezone(timezone.utc)
        age = response.headers.get('age', '0')
        if not age.isdigit():
            raise ValueError('Malformed cache age')
        if base > retrieved:
            raise ValueError('Source response date is in the future')
        # Date is the origin response time; Age describes its age at retrieval.
        # Do not subtract Age from Date a second time. Choose the older bound.
        return min(base, retrieved - timedelta(seconds=int(age)))

    @staticmethod
    def _timestamp(value):
        if value is None:
            return None
        parsed = datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError('Price validity timestamp must be timezone-aware')
        return parsed.astimezone(timezone.utc)

    @staticmethod
    def _quantity(text):
        # Multipacks, ranges and mixed dimensions need more explicit package data.
        if re.search(r'\d\s*(?:[x×]|[-–])\s*\d|pack\s+of|\d\s*(?:packs?|pk)\b', text, re.I):
            return None, None
        matches = list(_SIZE.finditer(text))
        if not 1 <= len(matches) <= 2:
            return None, None
        sizes = []
        for match in matches:
            unit = re.sub(r'\s+', '_', match['unit'].lower())
            unit = {'lb': 'lb', 'lbs': 'lb', 'count': 'each', 'ct': 'each', 'each': 'each', 'floz': 'fl_oz'}.get(unit, unit)
            sizes.append((Decimal(match['value']), unit))
        if len(sizes) == 2:
            (first, a), (second, b) = sizes
            # Alternate metric labeling is commonly rounded. Retain the first
            # printed size only when both labels describe approximately one pack.
            if UNITS[a][0] != UNITS[b][0] or a == b or first <= 0:
                return None, None
            ratio = second * BASE_FACTORS[b] / (first * BASE_FACTORS[a])
            if not Decimal('.97') <= ratio <= Decimal('1.03'):
                return None, None
        return sizes[0]
