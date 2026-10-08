"""Dimension-safe comparisons without binary floating-point arithmetic."""

from datetime import datetime, timedelta, timezone
from decimal import Decimal, localcontext

UNITS = {
    "oz": ("oz", Decimal("1")),
    "lb": ("oz", Decimal("16")),
    "g": ("oz", None),
    "kg": ("oz", None),
    "fl_oz": ("fl_oz", Decimal("1")),
    "ml": ("fl_oz", None),
    "l": ("fl_oz", None),
    "each": ("each", Decimal("1")),
}

# Exact finite conversions to grams, milliliters or count. Converting each
# quantity to rounded ounces before taking a ceiling can overcount packages.
BASE_FACTORS = {
    "oz": Decimal("28.349523125"), "lb": Decimal("453.59237"),
    "g": Decimal("1"), "kg": Decimal("1000"),
    "fl_oz": Decimal("29.5735295625"), "ml": Decimal("1"),
    "l": Decimal("1000"), "each": Decimal("1"),
}


def package_outlay(observation: dict, staple: dict) -> dict | None:
    required = staple.get("desired_quantity")
    desired_unit = staple.get("desired_unit")
    if required is None or desired_unit is None:
        return None
    if observation.get("quantity_kind", "fixed") != "fixed":
        return None
    unit = observation["unit"]
    if UNITS[unit][0] != UNITS[desired_unit][0]:
        return None
    with localcontext() as context:
        context.prec = 60
        package = Decimal(observation["quantity"]) * observation["pack_count"] * BASE_FACTORS[unit]
        need = Decimal(required) * BASE_FACTORS[desired_unit]
        # divmod computes the ceiling from exact decimal integers/remainders,
        # avoiding a rounded quotient near an exact package boundary.
        whole, remainder = divmod(need, package)
        count = int(whole) + int(remainder != 0)
        excess = (package * count - need) / BASE_FACTORS[desired_unit]
        return {"purchase_cost": format(Decimal(observation["price"]) * count, "f"),
                "excess_quantity": format(excess, "f"), "excess_unit": desired_unit,
                "packages_needed": count}


def unit_price(observation: dict, basis: str) -> Decimal | None:
    dimension, factor = UNITS[observation["unit"]]
    if dimension != basis:
        return None
    with localcontext() as context:
        context.prec = 50
        total = Decimal(observation["quantity"]) * observation["pack_count"]
        # Divide by an exact metric conversion to avoid rounding reciprocals.
        if observation["unit"] in {"g", "kg"}:
            total = total * (1000 if observation["unit"] == "kg" else 1) / Decimal("28.349523125")
        elif observation["unit"] in {"ml", "l"}:
            total = total * (1000 if observation["unit"] == "l" else 1) / Decimal("29.5735295625")
        else:
            total *= factor
        return Decimal(observation["price"]) / total


def compare(staple: dict, observations: list[dict], now: datetime | None = None,
            channel: str = "in_store") -> dict:
    if channel not in {"in_store", "pickup"}:
        raise ValueError(f"Unknown comparison channel: {channel}")
    now = now or datetime.now(timezone.utc)
    offers = []
    candidates = []
    cost_candidates = []
    for row in observations:
        normalized = unit_price(row, staple["basis"])
        reasons = []
        if row.get('source_exclusion'):
            reasons.append(row['source_exclusion'])
        if row.get('valid_from') and now < datetime.fromisoformat(row['valid_from']):
            reasons.append('offer_not_started')
        if row.get('valid_until') and now >= datetime.fromisoformat(row['valid_until']):
            reasons.append('offer_expired')
        if normalized is None:
            reasons.append("incompatible_dimension")
        if row.get("quantity_kind", "fixed") != "fixed":
            reasons.append("uncertain_quantity")
        # Persistent match state is authoritative. The legacy observation flag
        # is retained as historical input, never an override for a pending match.
        if "match_status" in row:
            if row["match_status"] != "approved":
                reasons.append("match_rejected" if row["match_status"] == "rejected" else "not_approved")
        elif not row["approved"]:
            reasons.append("not_approved")
        if not row["available"]:
            reasons.append("unavailable")
        if not row.get("is_current_context", True):
            reasons.append("location_not_current")
        if not row.get("location_configured", True) or row.get("store_location", "").strip().lower() == "unselected":
            reasons.append("location_not_configured")
        if row["channel"] != channel:
            reasons.append("not_in_store" if channel == "in_store" else f"not_{channel}")
        age = now - datetime.fromisoformat(row["observed_at"])
        if age < timedelta(0):
            reasons.append("future_observation")
        elif age >= timedelta(hours=48):
            reasons.append("stale")
        if row["conditions"].strip():
            reasons.append("conditional_price")
        offer = dict(row, unit_price=format(normalized, "f") if normalized is not None else None,
                     basis=staple["basis"], eligible=not reasons, exclusion_reasons=reasons)
        outlay = package_outlay(row, staple) if not reasons else None
        if outlay:
            offer.update(outlay)
        offers.append(offer)
        if not reasons:
            candidates.append((normalized, row["id"]))
            if outlay:
                cost_candidates.append((Decimal(outlay["purchase_cost"]), row["id"]))
    winner_id = min(candidates)[1] if candidates else None
    return {"staple": staple, "offers": offers, "winner_id": winner_id,
            "unit_price_winner_id": winner_id,
            "purchase_cost_winner_id": min(cost_candidates)[1] if cost_candidates else None,
            "purchase_gap": ("quantity_not_requested" if staple.get("desired_quantity") is None
                             else None if cost_candidates else "no_eligible_offers"),
            "channel": channel,
            "gap": None if winner_id is not None else ("no_observations" if not offers else "no_eligible_offers")}
