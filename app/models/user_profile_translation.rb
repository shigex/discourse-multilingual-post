# frozen_string_literal: true

class UserProfileTranslation < ActiveRecord::Base
  self.table_name = "user_profile_translations"

  TRANSLATABLE_FIELDS = %w[bio_raw hobbies stay_period].freeze
  STATUSES = %w[pending completed failed].freeze

  belongs_to :user

  validates :user_id, presence: true
  validates :field_name, presence: true, inclusion: { in: TRANSLATABLE_FIELDS }
  validates :locale, presence: true,
                     inclusion: { in: ::MultilingualPost::SUPPORTED_LOCALES }
  validates :source_locale, presence: true
  validates :raw, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :locale, uniqueness: { scope: %i[user_id field_name] }

  def self.upsert_completed(user_id:, field_name:, locale:, raw:, source_locale:)
    record = find_or_initialize_by(user_id: user_id, field_name: field_name, locale: locale)
    record.assign_attributes(
      raw: raw,
      source_locale: source_locale,
      status: "completed",
      error_message: nil,
    )
    record.save!
    record
  end
end
