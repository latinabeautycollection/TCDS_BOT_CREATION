# Cross-Solution Reconciliation

Reviewed inputs:
- ZSL5 V1.2 final freeze candidate
- ZSL1 national tax source acquisition V1.1
- ZSL5 V1.3 source-extension hardening
- ZSL1→ZSL5 reconciled V1.0 integration
- National tax runtime population V1.0
- supplied ZSL schema

Key reconciliation decisions:
1. V1.2 remains historical compatibility only until a V1.4 authority is certified and activated.
2. V1.3 and the prior V1.0 integration used an 8-category tax-mapping assumption. This package supersedes that assumption with 10 required categories.
3. GAME_CONSOLES remains a dedicated category and is not collapsed into generic ELECTRONICS.
4. CAMERAS is added as a first-class governed category.
5. ELECTRONICS is added as a broad business category but requires governed subclass refinement; it cannot silently become a universal tax class.
6. The 21 external tax-source families remain unchanged. Category taxonomy is an internal ZSL5 policy surface, not a 22nd source family.
7. The 042→046 migration chain in this package is the only merge target; do not stack older runtime/integration overlays afterward.
