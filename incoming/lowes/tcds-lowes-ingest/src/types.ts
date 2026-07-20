import { z } from 'zod';

const nullableString = z.string().nullable().optional();
const nullableArray = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess((value) => value == null ? [] : value, z.array(schema));
const nullableNumber = z.union([z.number(), z.string()]).nullable().optional();

export const LowesRecordSchema = z.object({
  url: z.string().url().refine((value) => {
    const host = new URL(value).hostname.toLowerCase();
    return host === 'lowes.com' || host.endsWith('.lowes.com');
  }, 'Product URL must belong to lowes.com'),
  domain: nullableString,
  marketplace_pn: z.union([z.string(), z.number()]).transform(String),
  sku: z.union([z.string(), z.number()]).nullable().optional().transform(v => v == null ? null : String(v)),
  other_pn: z.union([z.string(), z.number()]).nullable().optional().transform(v => v == null ? null : String(v)),
  model_number: nullableString,
  gtin_ean_pn: nullableString,
  upc: nullableString,
  product_name: z.string().trim().min(1),
  brand: nullableString,
  description: nullableString,
  date_first_available: nullableString,
  badges: nullableArray(z.string()),
  initial_price: nullableNumber,
  final_price: nullableNumber,
  price: nullableNumber,
  sale_price: nullableNumber,
  discount: nullableNumber,
  currency: nullableString,
  delivery_offers: z.unknown().nullable().optional(),
  in_stock: z.boolean().nullable().optional(),
  availability: nullableArray(z.string()),
  availability_status: nullableString,
  availability_date: nullableString,
  delivery: nullableArray(z.unknown()),
  seller_name: nullableString,
  seller_id: nullableString,
  seller_url: z.string().url().nullable().optional(),
  root_category: nullableString,
  'breadcrumbs ': z.unknown().nullable().optional(),
  main_image: z.string().url().nullable().optional(),
  image_urls: nullableArray(z.string().url()),
  additional_image_urls: nullableArray(z.string().url()),
  videos: nullableArray(z.unknown()),
  rating: z.number().min(0).max(5).nullable().optional(),
  reviews_count: z.number().int().nonnegative().nullable().optional(),
  reviews: nullableArray(z.unknown()),
  top_reviews: nullableArray(z.unknown()),
  color: nullableString,
  other_attribute: nullableString,
  features: z.unknown().nullable().optional(),
  dimensions: z.record(z.unknown()).nullable().optional(),
  weight: nullableString,
  category_tree: nullableArray(z.string()),
  nai_category_tree: nullableArray(z.object({
    name: z.string().trim().min(1),
    url: z.string().url().nullable().optional()
  })),
  product_category: nullableString,
  variations: z.unknown().nullable().optional(),
  related_searches: z.unknown().nullable().optional(),
  Specifications: nullableArray(z.unknown()),
  customers_also_viewed: z.unknown().nullable().optional(),
  better_together: z.unknown().nullable().optional(),
  available_to_delivery: z.number().int().nonnegative().nullable().optional(),
  location: nullableString,
  store_name: nullableString,
  group_id: z.union([z.string(), z.number()]).nullable().optional().transform(v => v == null ? null : String(v)),
  listing_has_variations: z.boolean().nullable().optional().transform(v => v ?? false),
  variant_attributes: nullableArray(z.unknown()),
  variants: nullableArray(z.unknown()),
  seller_privacy_policy: z.string().url().nullable().optional(),
  seller_tos: z.string().url().nullable().optional(),
  return_policy: z.string().url().nullable().optional(),
  return_window: z.number().int().nonnegative().nullable().optional(),
  target_countries: nullableArray(z.string()),
  store_country: nullableString,
  category_urls: nullableArray(z.string().url()),
  in_store_location: z.object({ aisle: nullableString, bay: nullableString }).nullable().optional()
}).passthrough();

export type LowesRecord = z.infer<typeof LowesRecordSchema>;
export type SnapshotStatus = { snapshot_id?: string; id?: string; status?: string; dataset_id?: string; error?: unknown; };
