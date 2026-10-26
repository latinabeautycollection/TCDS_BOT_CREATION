# TCDS Tax Product Taxonomy V3

The tax runtime does not treat a Retail business category as a legal tax class. The governed mapping layer translates TCDS categories to tax classes and optional subclasses.

Required scope is 10 categories: LAPTOPS, PHONES, NETWORKING, AUTOMOTIVE_TOOLS, GARDENING_TOOLS, GAME_CONSOLES, MUSIC_EQUIPMENT, DRONES, CAMERAS, ELECTRONICS.

`GAME_CONSOLES` remains a dedicated tax category and is not collapsed into generic electronics. `CAMERAS` maps to CAMERA with governed subclasses. `ELECTRONICS` maps to ELECTRONIC_EQUIPMENT but requires subclass refinement before quote execution because generic electronics can hide materially different tax treatment.

Caller-supplied `taxProductClass` cannot override the governed mapping. A mismatch fails closed. Unknown subclasses also fail closed.
