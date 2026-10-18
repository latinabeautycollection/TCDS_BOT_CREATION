# R1B Integration Contract

The attached R1B V4 schema uses `retail.search_locations` with a single `parent_location_id` and location types national/region/state/metro/postal_code/store. ZSL2's factual geography is many-to-many (ZIPs can cross counties; CBSAs cross states). Therefore ZSL2 MUST NOT copy its canonical graph into R1B as if it were a tree.

ZSL2 publishes `zsl.r1b_location_candidates` and `zsl.r1b_location_sync_proposals`. A later integration slice must select a governed R1B search-tree projection, validate current ZSL2 certification, and create only draft/verified R1B locations. R1B remains the sole approval authority.

Metro proposals are withheld until `zsl.cbsa_metros.name_authority_status='AUTHORITATIVE'`. Postal proposals are withheld until USPS validation in ZSL3. State proposals may be emitted from Census authority after ZSL2 certification.
