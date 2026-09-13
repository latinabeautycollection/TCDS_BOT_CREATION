# R1C V2 Domain Contract

Authority chain:

ARB -> R1A effective targets -> R1B effective routes -> R1C effective compiled jobs -> R1D

R1C owns compilation semantics only.

`compile_mode` is explicit and route-specific:
- keyword
- category
- product_url
- store_inventory

The certified adapter input contract must enumerate the compile mode and map every required canonical field to the concrete adapter parameter name.

For nationwide retail search, R1B decides the location; R1C emits the exact store/ZIP/region fields. R1D later decides which geographic routes to run, when, and under what Bright Data budget.
