// SocialLinks — renders an org's configured social handles as icon links.
//
// Driven by `org.marketing.socials` (public handles, no secrets). Each value
// may be a full URL or a bare handle; socialHref normalizes both to a real
// destination. Renders nothing when no socials are configured.

import { Instagram, Facebook, Twitter, Globe, Music2 } from 'lucide-react';

type Socials = NonNullable<NonNullable<import('../types').Organization['marketing']>['socials']>;

interface Props {
  socials?: Socials;
  className?: string;
  iconClassName?: string;
}

const ORDER: { key: keyof Socials; label: string; Icon: typeof Instagram }[] = [
  { key: 'instagram', label: 'Instagram', Icon: Instagram },
  { key: 'tiktok', label: 'TikTok', Icon: Music2 },
  { key: 'x', label: 'X', Icon: Twitter },
  { key: 'facebook', label: 'Facebook', Icon: Facebook },
  { key: 'website', label: 'Website', Icon: Globe },
];

export function socialHref(platform: keyof Socials, raw: string): string {
  const v = raw.trim();
  if (!v) return '';
  if (/^https?:\/\//i.test(v)) return v;
  const handle = v.replace(/^@/, '');
  switch (platform) {
    case 'instagram':
      return `https://instagram.com/${handle}`;
    case 'tiktok':
      return `https://tiktok.com/@${handle}`;
    case 'x':
      return `https://x.com/${handle}`;
    case 'facebook':
      return `https://facebook.com/${handle}`;
    case 'website':
      return `https://${v}`;
    default:
      return v;
  }
}

export default function SocialLinks({ socials, className, iconClassName }: Props) {
  if (!socials) return null;
  const links = ORDER.map(({ key, label, Icon }) => {
    const raw = socials[key];
    if (!raw) return null;
    const href = socialHref(key, raw);
    if (!href) return null;
    return (
      <a
        key={key}
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={label}
        className={iconClassName ?? 'text-white/40 hover:text-white transition-colors'}
      >
        <Icon className="w-5 h-5" />
      </a>
    );
  }).filter(Boolean);

  if (links.length === 0) return null;
  return <div className={className ?? 'flex items-center gap-5'}>{links}</div>;
}
