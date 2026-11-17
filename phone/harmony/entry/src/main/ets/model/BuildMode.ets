import BuildProfile from 'entry/BuildProfile';

/** Generated product metadata is the only switch for temporary preview adapters. */
export function previewMode():boolean {
  return String(BuildProfile.PRODUCT_NAME)==='preview' && BuildProfile.DEBUG;
}
