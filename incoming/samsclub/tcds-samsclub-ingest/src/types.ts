import { z } from 'zod';

const nullableString = z.string().nullable().optional();
const nullableArray = <T extends z.ZodTypeAny>(schema: T) =>
  z.preprocess((value) => value == null ? [] : value, z.array(schema));

export const SamsClubRecordSchema = z.object({
  url: z.string().url().refine((value) => {
    const host = new URL(value).hostname.toLowerCase();
    return host === 'samsclub.com' || host.endsWith('.samsclub.com');
  }, 'Product URL must belong to samsclub.com'),
  item_id: z.union([z.string(), z.number()]).transform(String),
  variant_id: z.union([z.string(), z.number()]).nullable().optional().transform(v => v == null ? null : String(v)),
  gtin: nullableString,
  mpn: nullableString,
  title: z.string().trim().min(1),
  description: nullableString,
  product_category: nullableString,
  category_tree: nullableArray(z.object({
    name: z.string().trim().min(1),
    url: z.string().url().nullable().optional()
  })),
  brand: nullableString,
  image_url: z.string().url().nullable().optional(),
  additional_image_urls: nullableArray(z.string().url()),
  price: z.union([z.string(), z.number()]).nullable().optional(),
  sale_price: z.union([z.string(), z.number()]).nullable().optional(),
  availability: nullableString,
  availability_date: nullableString,
  group_id: z.union([z.string(), z.number()]).nullable().optional().transform(v => v == null ? null : String(v)),
  listing_has_variations: z.boolean().nullable().optional().transform(v => v ?? false),
  variant_attributes: nullableArray(z.unknown()),
  variants: nullableArray(z.unknown()),
  store_name: nullableString,
  seller_url: z.string().url().nullable().optional(),
  seller_privacy_policy: z.string().url().nullable().optional(),
  seller_tos: z.string().url().nullable().optional(),
  return_policy: z.string().url().nullable().optional(),
  return_window: z.number().int().nonnegative().nullable().optional(),
  review_count: z.number().int().nonnegative().nullable().optional(),
  star_rating: z.number().min(0).max(5).nullable().optional(),
  reviews: nullableArray(z.unknown()),
  target_countries: nullableArray(z.string()),
  store_country: nullableString,
  category_urls: nullableArray(z.string().url())
}).passthrough();

export type SamsClubRecord = z.infer<typeof SamsClubRecordSchema>;
export type SnapshotStatus = {
  snapshot_id?: string;
  id?: string;
  status?: string;
  dataset_id?: string;
  error?: unknown;
};
