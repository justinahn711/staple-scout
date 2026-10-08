"""Verified source capabilities. Constructing a registry never fetches prices."""
from .adapters import AdapterRegistration
from .hmart import HMartAdapter


def default_sources():
    # Five-product online evidence gate and exact-ID smoke are documented in
    # docs/research/hmart.md. This does not verify Centreville shelf/pickup prices.
    source = AdapterRegistration(
        source_id='hmart_online', retailer='hmart', adapter=HMartAdapter(),
        channels=frozenset({'online'}), sellers=frozenset({'HMart - US'}),
        validated=True, timeout=10,
    )
    return {source.source_id: source}
