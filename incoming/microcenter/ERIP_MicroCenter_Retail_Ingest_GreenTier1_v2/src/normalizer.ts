import { z } from "zod";
import { bool, first, integer, number, sha256, text, uuid } from "./util.js";

const JsonObject = z.record(z.unknown());

export type Normalized = {
  product: {
    retail_product_id: string;
    retailer_product_key: string;
    retailer_sku: string | null;
    upc: string | null;
    gtin: string | null;
    mpn: string | null;
    brand: string | null;
    model: string | null;
    title: string;
    product_url: string | null;
    image_url: string | null;
    category_text: string | null;
    condition_text: string | null;
    seller_name: string | null;
    identity_confidence: number;
    latest_payload: Record<string, unknown>;
  };
  offer: {
    retail_offer_snapshot_id: string;
    source_record_hash: string;
    currency_code: string;
    current_price: number | null;
    original_price: number | null;
    shipping_cost: number | null;
    in_stock: boolean | null;
    stock_text: string | null;
    store_id: string | null;
    store_name: string | null;
    rating: number | null;
    review_count: number | null;
    evidence_confidence: number;
    observed_at: string;
    payload: Record<string, unknown>;
  };
};

export type NormalizeResult =
  | { ok: true; value: Normalized }
  | { ok: false; code: string; message: string };

function digits(v: string | null): string | null {
  if (!v) return null;
  const d = v.replace(/\D/g, "");
  return d.length >= 8 && d.length <= 14 ? d : null;
}

export function normalizeMicroCenter(raw: unknown, observedAt: string): NormalizeResult {
  const parsed = JsonObject.safeParse(raw);
  if (!parsed.success) return { ok: false, code: "NOT_JSON_OBJECT", message: "Record is not a JSON object." };
  const o = parsed.data;

  const title = text(first(o, ["title","product_name","name","product_title","item_name"]));
  const productUrl = text(first(o, ["url","product_url","link","product_link"]));
  const retailerId = text(first(o, ["product_id","retailer_product_id","item_id","id"]));
  const sku = text(first(o, ["sku","sku_id","product_sku","item_sku"]));
  const upc = digits(text(first(o, ["upc","barcode"])));
  const gtin = digits(text(first(o, ["gtin","ean"])));
  const mpn = text(first(o, ["mpn","manufacturer_part_number"]));
  const brand = text(first(o, ["brand","brand_name","manufacturer"]));
  const model = text(first(o, ["model","model_number"]));
  const currentPrice = number(first(o, ["price","current_price","sale_price","final_price","product_price"]));
  const originalPrice = number(first(o, ["original_price","regular_price","list_price","msrp"]));
  const shippingCost = number(first(o, ["shipping_cost","shipping","delivery_cost"]));
  const stockText = text(first(o, ["availability","stock_status","inventory_status","stock"]));
  const inStock = bool(first(o, ["in_stock","available","is_available"])) ?? bool(stockText);
  const storeId = text(first(o, ["store_id","location_id"]));
  const storeName = text(first(o, ["store_name","location_name","store"]));
  const imageUrl = text(first(o, ["image_url","image","thumbnail","main_image"]));
  const category = text(first(o, ["category","category_name","breadcrumbs"]));
  const condition = text(first(o, ["condition","item_condition"]));
  const seller = text(first(o, ["seller","seller_name","merchant","sold_by"]));
  const rating = number(first(o, ["rating","stars","review_rating"]));
  const reviewCount = integer(first(o, ["review_count","reviews_count","number_of_reviews"]));
  const currency = text(first(o, ["currency","currency_code"])) ?? "USD";

  if (!title) return { ok: false, code: "MISSING_TITLE", message: "No recognized title field." };
  if (!productUrl && !retailerId && !sku && !upc && !gtin) {
    return { ok: false, code: "MISSING_IDENTITY", message: "No URL, retailer ID, SKU, UPC or GTIN." };
  }

  const key = upc ? `upc:${upc}` :
    gtin ? `gtin:${gtin}` :
    sku ? `sku:${sku.toLowerCase()}` :
    retailerId ? `retailer:${retailerId.toLowerCase()}` :
    brand && model ? `brand-model:${brand.toLowerCase()}|${model.toLowerCase()}` :
    `url:${productUrl!.toLowerCase()}`;

  let identity = 0.20;
  if (productUrl) identity += 0.10;
  if (retailerId || sku) identity += 0.20;
  if (upc || gtin) identity += 0.30;
  if (brand) identity += 0.10;
  if (model || mpn) identity += 0.10;
  identity = Math.min(1, identity);

  let evidence = identity * 0.65;
  if (currentPrice !== null) evidence += 0.20;
  if (stockText !== null || inStock !== null) evidence += 0.10;
  if (rating !== null || reviewCount !== null) evidence += 0.05;
  evidence = Math.min(1, evidence);

  const sourceHash = sha256({
    key,
    currentPrice,
    originalPrice,
    shippingCost,
    inStock,
    storeId,
    observed_hour: observedAt.slice(0, 13)
  });

  return {
    ok: true,
    value: {
      product: {
        retail_product_id: uuid(),
        retailer_product_key: key,
        retailer_sku: sku ?? retailerId,
        upc,
        gtin,
        mpn,
        brand,
        model,
        title,
        product_url: productUrl,
        image_url: imageUrl,
        category_text: category,
        condition_text: condition,
        seller_name: seller,
        identity_confidence: Number(identity.toFixed(5)),
        latest_payload: o
      },
      offer: {
        retail_offer_snapshot_id: uuid(),
        source_record_hash: sourceHash,
        currency_code: currency,
        current_price: currentPrice,
        original_price: originalPrice,
        shipping_cost: shippingCost,
        in_stock: inStock,
        stock_text: stockText,
        store_id: storeId,
        store_name: storeName,
        rating,
        review_count: reviewCount,
        evidence_confidence: Number(evidence.toFixed(5)),
        observed_at: observedAt,
        payload: o
      }
    }
  };
}
