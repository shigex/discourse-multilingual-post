# frozen_string_literal: true

# ----------------------------------------------------------------------------
# seed_categories.rb
# Bayview Multilingual BBS — initial category seeding for the launch site.
#
# Idempotent: re-running this script will NOT duplicate categories. It
# locates each category by slug and updates name / description / color /
# permissions in place.
#
# How to run (Discourse standard launcher container):
#
#   # Copy this file into the running app container:
#   docker cp seeds/seed_categories.rb discourse_app:/tmp/seed_categories.rb
#
#   # Execute as the discourse user via rails runner:
#   docker exec -u discourse -i discourse_app \
#     bundle exec rails runner /tmp/seed_categories.rb
#
# Or, from inside the container shell:
#
#   ./launcher enter app
#   cd /var/www/discourse
#   sudo -u discourse RAILS_ENV=production bundle exec rails runner \
#     /tmp/seed_categories.rb
#
# Multisite deployments: prepend RAILS_DB=<site_name>, e.g.
#
#   RAILS_ENV=production RAILS_DB=bayview \
#     bundle exec rails runner seeds/seed_categories.rb
#
# Safe to re-run after edits — existing categories are updated in place.
# ----------------------------------------------------------------------------

# Each entry mirrors PLAN.md §「カテゴリ構成（ローンチ時）」.
#
#   :name              English display name (translated to per-user locale at
#                      render time by the multilingual-post plugin).
#   :slug              URL slug (must be unique, ASCII).
#   :description       One-line English description; also auto-translated.
#   :color             Hex (no #) for the category badge background.
#   :text_color        Hex (no #) for the category badge text.
#   :emoji             Decorative emoji prefixed to the description for
#                      visual recognition in category lists.
#   :staff_only        When true, only staff (admins/moderators) can create
#                      topics; everyone else is read-only.
CATEGORIES = [
  {
    name: "Announcements",
    slug: "announcements",
    emoji: "📢",
    color: "B36AE2",
    text_color: "FFFFFF",
    description: "Official notices from the BBS admin (Shige). Read-only for residents.",
    staff_only: true,
  },
  {
    name: "Kitchen & Food",
    slug: "kitchen-food",
    emoji: "🍳",
    color: "F2A93B",
    text_color: "FFFFFF",
    description: "Shared fridge etiquette, recipe swaps, leftover give-aways, late-night snack tips.",
  },
  {
    name: "Laundry / Gym / Facilities",
    slug: "facilities",
    emoji: "🧺",
    color: "4F8EF7",
    text_color: "FFFFFF",
    description: "Broken machines, busy hours, lost items in shared spaces.",
  },
  {
    name: "Events & Meetups",
    slug: "events",
    emoji: "🎉",
    color: "8FBC4B",
    text_color: "FFFFFF",
    description: "Resident-organized hangouts, day trips, language exchanges, study groups.",
  },
  {
    name: "Marketplace",
    slug: "marketplace",
    emoji: "🛒",
    color: "EB5757",
    text_color: "FFFFFF",
    description: "Sell, give away, lend, or look for items. Move-out furniture welcome.",
  },
  {
    name: "Help / Tips",
    slug: "help",
    emoji: "❓",
    color: "00A693",
    text_color: "FFFFFF",
    description: "Trash schedule, immigration paperwork, neighborhood know-how, questions for fellow residents.",
  },
  {
    name: "Lounge",
    slug: "lounge",
    emoji: "💬",
    color: "9B51E0",
    text_color: "FFFFFF",
    description: "Casual chat. Anything off-topic. Be kind, be curious.",
  },
  {
    name: "Site Feedback",
    slug: "site-feedback",
    emoji: "🔧",
    color: "777777",
    text_color: "FFFFFF",
    description: "Bugs, feature requests, translation glitches. Help us improve the BBS.",
  },
].freeze

system_user_id = Discourse.system_user.id

CATEGORIES.each do |cat|
  description_with_emoji = "#{cat[:emoji]} #{cat[:description]}"

  category = Category.find_or_initialize_by(slug: cat[:slug])
  is_new = category.new_record?

  category.assign_attributes(
    name: cat[:name],
    color: cat[:color],
    text_color: cat[:text_color],
    user_id: system_user_id,
    description: description_with_emoji,
  )
  category.save!

  # Permissions: Announcements is staff-write / everyone-read.
  # Other categories are open to all logged-in users (Discourse default for
  # categories without explicit per-group permissions).
  if cat[:staff_only]
    category.set_permissions(staff: :full, everyone: :readonly)
    category.save!
  else
    # Explicit reset in case a previous seeding left restrictive permissions
    # on a category that is now meant to be open.
    category.set_permissions(everyone: :full)
    category.save!
  end

  marker = is_new ? "created" : "updated"
  puts "  [#{marker}] #{cat[:emoji]} #{category.name} (id=#{category.id}, slug=#{category.slug})"
end

puts ""
puts "Seeded #{CATEGORIES.size} categories."
puts "Next step: pin the rules-<locale>.md topics (see seeds/rules/) into Announcements."
