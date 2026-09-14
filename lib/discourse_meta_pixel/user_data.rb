# frozen_string_literal: true

require "digest"
require "openssl"

module DiscourseMetaPixel
  # Builds the `user_data` block of a Conversions API event.
  #
  # Meta's customer-information parameter rules are precise about what must be
  # hashed and how it must be normalized first, and hashing an un-normalized
  # value produces a hash that simply never matches anyone — a silent failure
  # that looks like poor match quality rather than a bug. So normalization is
  # implemented explicitly here, next to the hashing, and tested on its own.
  #
  # Rules implemented (from Meta's customer information parameters docs):
  #
  #   em          SHA-256 of the email, trimmed and lowercased
  #   external_id opaque, stable, never a username or email
  #   client_ip_address   plain, taken from the real request
  #   client_user_agent   plain, taken from the real request
  #   fbp / fbc   plain, exactly as the first-party cookie holds them
  #
  # Nothing here ever logs, persists or returns a raw email.
  module UserData
    module_function

    # Meta: "Trim any leading and trailing spaces. Convert all characters to
    # lowercase." Then SHA-256, lowercase hex.
    def hash_email(email)
      normalized = normalize_email(email)
      return nil if normalized.nil?

      Digest::SHA256.hexdigest(normalized)
    end

    def normalize_email(email)
      value = email.to_s.strip.downcase
      return nil if value.empty?
      # A value with no "@" is not an email; hashing it would add a
      # never-matching identifier to every event.
      return nil unless value.include?("@")

      value
    end

    # An opaque, stable, per-user identifier.
    #
    # Never the username and never the email: Meta's `external_id` is stored
    # and used for matching across advertisers, so handing over a value that
    # *is* the user's forum identity would export that identity. An HMAC keyed
    # on server-side secret material is stable enough to match the same person
    # across events and useless to anyone without the key.
    #
    # Keyed on Discourse's own secret, so it is not derivable from public
    # information and does not require a new secret setting to be managed.
    def external_id(user_id, secret)
      return nil if user_id.nil? || user_id.to_s.strip.empty?
      return nil if secret.to_s.empty?

      OpenSSL::HMAC.hexdigest("SHA256", secret.to_s, "meta-external-id:#{user_id}")
    end

    # Assemble the block, omitting anything absent.
    #
    # Meta ignores unknown or empty keys, but sending empty strings degrades
    # match quality reporting, so absent means absent.
    def build(
      email: nil,
      user_id: nil,
      secret: nil,
      client_ip_address: nil,
      client_user_agent: nil,
      fbp: nil,
      fbc: nil,
      enhanced_email: false,
      external_id_enabled: false
    )
      data = {}

      if enhanced_email
        hashed = hash_email(email)
        data[:em] = [hashed] if hashed
      end

      if external_id_enabled
        id = external_id(user_id, secret)
        data[:external_id] = [id] if id
      end

      data[:client_ip_address] = present(client_ip_address)
      data[:client_user_agent] = present(client_user_agent)
      data[:fbp] = fbp if valid_fbp?(fbp)
      data[:fbc] = fbc if valid_fbc?(fbc)

      data.reject { |_, v| v.nil? || (v.respond_to?(:empty?) && v.empty?) }
    end

    # Deliberately plain Ruby rather than ActiveSupport's `present?`: this file
    # is exercised by the standalone suite, which runs without Rails loaded.
    def present(value)
      return nil if value.nil?

      string = value.to_s
      string.strip.empty? ? nil : string
    end

    # `fb.<subdomainIndex>.<creationTime>.<value>`
    #
    # Validated rather than passed through: these are set by Meta's own Pixel
    # as first-party cookies, so a value that does not have the documented
    # shape did not come from the Pixel and should not be forwarded as though
    # it did. The plugin never fabricates either value.
    FBP_PATTERN = /\Afb\.\d\.\d+\.\d+\z/
    FBC_PATTERN = /\Afb\.\d\.\d+\.[\w.-]+\z/

    def valid_fbp?(value)
      return false if value.nil?

      FBP_PATTERN.match?(value.to_s)
    end

    def valid_fbc?(value)
      return false if value.nil?
      return false if value.to_s.length > 512

      FBC_PATTERN.match?(value.to_s)
    end

    # A representation safe to show an administrator or write to a log.
    #
    # Reports which matching signals were present, never their values — not
    # even the hashed email, which is still a stable per-person identifier.
    def redact(data)
      (data || {}).keys.map(&:to_s).sort
    end
  end
end
