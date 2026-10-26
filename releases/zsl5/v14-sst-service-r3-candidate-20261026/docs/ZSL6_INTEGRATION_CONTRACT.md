# ZSL5 → ZSL6 Tax Acquisition-Cost Contract

ZSL6 does not currently exist in the production repo/database. This package therefore does not create a `zsl6` schema, tables, or decision authority.

Future ZSL6 must consume the read-only view:
`zsl.zsl5_zsl6_acquisition_cost_authority_v14`

The contract exposes only quotes from the currently active ZSL5 V1.4 authority with valid upstream bindings and HIGH/PRESENT evidence. ZSL6 may consume:
- taxable base
- checkout tax estimate
- legal tax burden
- potential use tax
- mandatory government fees
- total government acquisition cost
- evidence SHA
- build/publication lineage
- evaluation timestamp

ZSL6 must not recalculate tax, alter tax evidence, or reinterpret ZSL5 legal rules. ZSL6 may combine the ZSL5 cost with retail/provider/logistics/warehouse/economic inputs to calculate acquisition economics.
