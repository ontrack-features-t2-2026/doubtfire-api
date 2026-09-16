# Style tokens for the notification mail layout.
#
# One map, so the badge at the top of a message, the rule above the card and the
# callout inside it all agree on the same colour. A template names a category and
# nothing else: it never repeats a hex value, and a new template that forgets to
# name one still renders in the neutral brand colour.
#
# The accents are deliberately a small set. Green means something arrived or
# completed, amber means a deadline is close, red means something failed and
# needs the recipient to act, and brand blue is everything neutral.
module NotificationMailHelper
  BRAND = '#3939ff'.freeze
  BRAND_TINT = '#f5f5ff'.freeze

  # Glyphs are written as HTML entities so the file stays ASCII and no mail
  # client has to guess at an encoding. Each one is a text-presentation
  # character from a block that ships with the core fonts on every platform, so
  # there is no icon font to strip and no emoji palette to fall back on.
  CATEGORIES = {
    'submission' => { glyph: '&#10003;', size: '24px', accent: '#067647', tint: '#ecfdf3', label: 'Submitted' },
    'portfolio' => { glyph: '&#9636;', size: '22px', accent: '#067647', tint: '#ecfdf3', label: 'Portfolio' },
    'feedback' => { glyph: '&#9998;', size: '22px', accent: BRAND, tint: BRAND_TINT, label: 'Feedback' },
    'comment' => { glyph: '&#8221;', size: '30px', accent: BRAND, tint: BRAND_TINT, label: 'Comment' },
    'announcement' => { glyph: '&#9733;', size: '22px', accent: BRAND, tint: BRAND_TINT, label: 'Announcement' },
    'session' => { glyph: '&#8635;', size: '24px', accent: BRAND, tint: BRAND_TINT, label: 'Schedule' },
    'extension' => { glyph: '+', size: '26px', accent: BRAND, tint: BRAND_TINT, label: 'Extension' },
    'group' => { glyph: '&#9679;&#9679;', size: '13px', accent: BRAND, tint: BRAND_TINT, label: 'Group' },
    'verification' => { glyph: '@', size: '22px', accent: BRAND, tint: BRAND_TINT, label: 'Verification' },
    'summary' => { glyph: '&#8801;', size: '24px', accent: BRAND, tint: BRAND_TINT, label: 'Summary' },
    'due' => { glyph: '!', size: '26px', accent: '#b54708', tint: '#fffaeb', label: 'Due soon' },
    'alert' => { glyph: '&#10007;', size: '24px', accent: '#b42318', tint: '#fef3f2', label: 'Needs attention' }
  }.freeze

  DEFAULT_CATEGORY = { glyph: '&#9733;', size: '22px', accent: BRAND, tint: BRAND_TINT, label: 'Notification' }.freeze

  # Look up a category. An unknown or blank name falls back to the neutral brand
  # styling rather than raising, because a message that renders plainly is a far
  # better failure than one that does not send at all.
  def notification_mail_style(category)
    CATEGORIES.fetch(category.to_s.strip, DEFAULT_CATEGORY)
  end

  def notification_mail_accent(category)
    notification_mail_style(category)[:accent]
  end
end
