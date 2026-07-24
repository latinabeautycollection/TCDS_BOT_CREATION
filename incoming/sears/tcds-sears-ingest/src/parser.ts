import type { SEARSRecord } from './types.js';

function decode(value: string): string {
  return value
    .replace(/&nbsp;/gi, ' ')
    .replace(/&amp;/gi, '&')
    .replace(/&#39;|&apos;/gi, "'")
    .replace(/&quot;/gi, '"')
    .replace(/&#(\d+);/g, (_match, code) => String.fromCodePoint(Number(code)));
}

function text(value: string): string {
  return decode(value.replace(/<[^>]+>/g, ' ')).replace(/\s+/g, ' ').trim();
}

function moneyFrom(fragment: string | undefined): string | null {
  return fragment?.match(/\$\s?[\d,]+(?:\.\d{2})?/)?.[0] ?? null;
}

function firstMatch(html: string, patterns: RegExp[]): string | null {
  for (const pattern of patterns) {
    const value = html.match(pattern)?.[1];
    if (value) return text(value);
  }
  return null;
}

export function parseSearsPdp(html: string, inputUrl: string): SEARSRecord {
  const canonical =
    html.match(/<link\b[^>]*rel=["']canonical["'][^>]*href=["']([^"']+)["']/i)?.[1] ??
    inputUrl;
  const url = new URL(decode(canonical), inputUrl);
  url.protocol = 'https:';
  url.hostname = 'www.sears.com';
  url.search = '';
  url.hash = '';
  url.pathname = url.pathname.replace(/\/+$/, '');

  const itemId = url.pathname.match(/\/p-([A-Za-z0-9_-]+)$/i)?.[1];
  if (!itemId) throw new Error('SEARS_ITEM_ID_NOT_FOUND');

  const title = firstMatch(html, [
    /<h1\b[^>]*class=["'][^"']*\bh2-ui-specs\b[^"']*["'][^>]*>([\s\S]*?)<\/h1>/i,
    /<h1\b[^>]*>([\s\S]*?)<\/h1>/i
  ]);
  if (!title) throw new Error('SEARS_TITLE_NOT_FOUND');

  const saleFragment =
    html.match(/class=["'][^"']*(?:pricing-sale-ui|sale-price-color)[^"']*["'][^>]*>([\s\S]{0,200}?)(?:<\/span>|<\/div>)/i)?.[1];
  const regularFragment =
    html.match(/class=["'][^"']*(?:pricing-crossed-ui|freq-price-regular)[^"']*["'][^>]*>([\s\S]{0,300}?)(?:<\/del>|<\/strong>)/i)?.[1];
  const finalFragment =
    html.match(/class=["'][^"']*product-final[^"']*["'][^>]*>([\s\S]{0,250}?)(?:<\/span>|<\/div>)/i)?.[1];
  const sale = moneyFrom(saleFragment);
  const regular = moneyFrom(regularFragment) ?? moneyFrom(finalFragment);
  if (!regular && !sale) throw new Error('SEARS_PRICE_NOT_FOUND');

  const specifications = [...html.matchAll(
    /class=["'][^"']*list-key[^"']*["'][^>]*>([\s\S]*?)<\/div>\s*<div\b[^>]*class=["'][^"']*list-value[^"']*["'][^>]*>([\s\S]*?)<\/div>/gi
  )].map(match => ({ name: text(match[1]!), value: text(match[2]!) }))
    .filter(row => row.name);
  const specification = (name: RegExp) =>
    specifications.find(row => name.test(row.name))?.value ?? null;

  const model = firstMatch(html, [
    /Model\s*#?\s*:\s*([^<]+)</i
  ]) ?? specification(/^model/i);
  const seller = firstMatch(html, [
    /Sold\s+By\s*<span\b[^>]*>([\s\S]*?)<\/span>/i
  ]);
  const description = firstMatch(html, [
    /<div\b[^>]*id=["']description["'][^>]*>([\s\S]*?)<div\b[^>]*id=["']specifications["']/i,
    /class=["'][^"']*handle-Short-description-tags[^"']*["'][^>]*>([\s\S]*?)<\/p>/i
  ]);
  const imageUrl =
    html.match(/id=["']pdp-main-image["'][\s\S]{0,500}?<img\b[^>]*src=["']([^"']+)["']/i)?.[1] ??
    null;
  const imageUrls = [...new Set(
    [...html.matchAll(/<img\b[^>]*src=["'](https:\/\/c\.shld\.net\/[^"']+)["']/gi)]
      .map(match => decode(match[1]!))
  )];
  const lower = text(html).toLowerCase();
  const availability = /out of stock|currently unavailable|not available/.test(lower)
    ? 'out_of_stock'
    : /sold by|add to cart|ship to/.test(lower)
      ? 'in_stock'
      : 'unknown';
  const brand = specification(/^brand$/i) ?? title.split(/\s+/)[0] ?? null;

  return {
    url: url.href,
    item_id: itemId.toUpperCase(),
    variant_id: null,
    title,
    description,
    product_category: 'Sears governed first-party product sitemap',
    category_tree: [],
    brand,
    image_url: imageUrl,
    additional_image_urls: imageUrls.filter(value => value !== imageUrl),
    additional_video_urls: [],
    gtin: specification(/^(?:upc|gtin)$/i),
    mpn: model,
    price: regular ?? sale,
    sale_price: sale && regular && sale !== regular ? sale : null,
    availability,
    availability_date: null,
    group_id: null,
    listing_has_variations: false,
    variant_attributes: specifications,
    variants: [],
    store_name: seller,
    seller_url: null,
    seller_privacy_policy: null,
    seller_tos: null,
    return_policy: null,
    return_window: null,
    target_countries: ['US'],
    store_country: 'US',
    category_urls: [],
    star_rating: null,
    review_count: null,
    reviews: []
  };
}
