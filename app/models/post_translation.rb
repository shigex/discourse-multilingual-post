# frozen_string_literal: true

class PostTranslation < ActiveRecord::Base
  self.table_name = "post_translations"

  STATUSES = %w[pending completed failed].freeze

  belongs_to :post

  validates :post_id, presence: true
  validates :locale, presence: true,
                     inclusion: { in: ::MultilingualPost::SUPPORTED_LOCALES }
  validates :source_locale, presence: true
  validates :raw, presence: true
  validates :status, inclusion: { in: STATUSES }
  validates :locale, uniqueness: { scope: :post_id }

  def self.upsert_completed(post_id:, locale:, raw:, source_locale:, cooked: nil)
    record = find_or_initialize_by(post_id: post_id, locale: locale)
    record.assign_attributes(
      raw: raw,
      cooked: cooked,
      source_locale: source_locale,
      status: "completed",
      error_message: nil,
    )
    record.save!
    record
  end

  def self.mark_failed(post_id:, locale:, source_locale:, error_message:)
    record = find_or_initialize_by(post_id: post_id, locale: locale)
    record.assign_attributes(
      raw: record.raw.presence || "",
      source_locale: source_locale,
      status: "failed",
      error_message: error_message,
    )
    record.save!
    record
  end
end
