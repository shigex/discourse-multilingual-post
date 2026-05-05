# frozen_string_literal: true

require "rails_helper"

describe MultilingualPost::AvatarImporter do
  fab!(:user) { Fabricate(:user) }

  before { user.create_user_avatar! unless user.user_avatar }

  let(:line_url)   { "https://profile.line-scdn.net/abcdef123" }
  let(:google_url) { "https://lh3.googleusercontent.com/a/ACg8ocAbCdEf=s96-c" }

  # Tiny 1x1 PNG so UploadCreator has something real to work with.
  let(:png_bytes) do
    [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ].pack("C*")
  end

  # Build a Tempfile-like object that mirrors the relevant OpenURI surface:
  # - readable in "rb" mode
  # - responds to #content_type
  # - responds to #close / #unlink so the ensure-block doesn't blow up
  def stub_fetch_with(content:, content_type: "image/png")
    tmp = Tempfile.new(%w[avatar-stub .png], binmode: true)
    tmp.write(content)
    tmp.rewind
    tmp.define_singleton_method(:content_type) { content_type }
    allow(described_class).to receive(:fetch).and_return(tmp)
    tmp
  end

  def stub_fetch_failure
    allow(described_class).to receive(:fetch).and_return(nil)
  end

  describe ".safe_https_url?" do
    it "accepts https URLs with a host" do
      expect(described_class.safe_https_url?("https://example.com/x.png")).to be true
    end

    it "rejects http://" do
      expect(described_class.safe_https_url?("http://example.com/x.png")).to be false
    end

    it "rejects file:// and other schemes (SSRF)" do
      expect(described_class.safe_https_url?("file:///etc/passwd")).to be false
      expect(described_class.safe_https_url?("ftp://example.com/x")).to be false
    end

    it "rejects malformed URLs" do
      expect(described_class.safe_https_url?("not a url")).to be false
      expect(described_class.safe_https_url?("https://")).to be false
    end
  end

  describe ".import_for" do
    context "no-op cases" do
      it "does nothing when user is nil" do
        expect(described_class).not_to receive(:fetch)
        described_class.import_for(nil, line_url)
      end

      it "does nothing when source_url is nil" do
        expect(described_class).not_to receive(:fetch)
        described_class.import_for(user, nil)
      end

      it "does nothing when source_url is blank" do
        expect(described_class).not_to receive(:fetch)
        described_class.import_for(user, "  ")
      end
    end

    context "URL validation" do
      it "rejects http:// without making a fetch call (SSRF defence)" do
        expect(described_class).not_to receive(:fetch)
        expect(Rails.logger).to receive(:warn).with(/insecure_scheme/)
        described_class.import_for(user, "http://example.com/avatar.png")
        expect(user.reload.uploaded_avatar_id).to be_nil
      end

      it "rejects malformed URLs without fetching" do
        expect(described_class).not_to receive(:fetch)
        expect(Rails.logger).to receive(:warn).with(/insecure_scheme/)
        described_class.import_for(user, "not a url at all")
      end
    end

    context "happy path" do
      it "imports a LINE avatar and updates uploaded_avatar_id" do
        stub_fetch_with(content: png_bytes, content_type: "image/png")
        fake_upload = double(persisted?: true, id: 12_345)
        creator = instance_double(UploadCreator, create_for: fake_upload)
        expect(UploadCreator).to receive(:new)
          .with(anything, "oauth-avatar-#{user.id}.png", type: "avatar")
          .and_return(creator)

        described_class.import_for(user, line_url)

        expect(user.reload.uploaded_avatar_id).to eq(12_345)
        expect(user.user_avatar.reload.custom_upload_id).to eq(12_345)
      end

      it "imports a Google avatar the same way" do
        stub_fetch_with(content: png_bytes, content_type: "image/jpeg")
        fake_upload = double(persisted?: true, id: 67_890)
        creator = instance_double(UploadCreator, create_for: fake_upload)
        expect(UploadCreator).to receive(:new).and_return(creator)

        described_class.import_for(user, google_url)

        expect(user.reload.uploaded_avatar_id).to eq(67_890)
      end
    end

    context "fetch failures" do
      it "logs and returns when fetch returns nil (network error / oversize / timeout)" do
        stub_fetch_failure
        expect(UploadCreator).not_to receive(:new)
        described_class.import_for(user, line_url)
        expect(user.reload.uploaded_avatar_id).to be_nil
      end
    end

    context "content-type validation" do
      it "rejects non-image content (e.g. HTML error page from CDN)" do
        stub_fetch_with(content: "<html>error</html>", content_type: "text/html")
        expect(UploadCreator).not_to receive(:new)
        expect(Rails.logger).to receive(:warn).with(/bad_content_type/)
        described_class.import_for(user, line_url)
        expect(user.reload.uploaded_avatar_id).to be_nil
      end

      it "rejects application/json (some providers return JSON errors)" do
        stub_fetch_with(content: '{"error":"expired"}', content_type: "application/json")
        expect(UploadCreator).not_to receive(:new)
        described_class.import_for(user, line_url)
        expect(user.reload.uploaded_avatar_id).to be_nil
      end
    end

    context "UploadCreator failure" do
      it "logs but does not modify the user when upload is not persisted" do
        stub_fetch_with(content: png_bytes, content_type: "image/png")
        errors = double(full_messages: ["File is not a valid image"])
        bad_upload = double(persisted?: false, errors: errors)
        creator = instance_double(UploadCreator, create_for: bad_upload)
        allow(UploadCreator).to receive(:new).and_return(creator)
        expect(Rails.logger).to receive(:warn).with(/upload_creator_failed/)

        described_class.import_for(user, line_url)
        expect(user.reload.uploaded_avatar_id).to be_nil
      end

      it "logs but does not modify the user when create_for returns nil" do
        stub_fetch_with(content: png_bytes, content_type: "image/png")
        creator = instance_double(UploadCreator, create_for: nil)
        allow(UploadCreator).to receive(:new).and_return(creator)
        expect(Rails.logger).to receive(:warn).with(/upload_creator_failed/)

        described_class.import_for(user, line_url)
        expect(user.reload.uploaded_avatar_id).to be_nil
      end
    end
  end

  describe ".fetch" do
    # We don't exercise OpenURI directly in unit tests — WebMock would have to
    # fake the entire HTTP stack including content_length_proc semantics.
    # Instead we cover the rescue branches by passing pathological inputs.

    it "returns nil and logs on URI parse error" do
      expect(Rails.logger).to receive(:warn).with(/fetch_error/)
      expect(described_class.fetch("ht!tp://bad url")).to be_nil
    end

    it "returns nil and logs when an exception bubbles out of OpenURI" do
      # Simulate the content_length_proc raising — OpenURI re-raises and we
      # should rescue it. Easier than coaxing WebMock into firing the proc.
      allow(URI).to receive(:parse).and_call_original
      allow_any_instance_of(URI::HTTPS).to receive(:open)
        .and_raise(StandardError, "avatar too large: 9999999 bytes")
      expect(Rails.logger).to receive(:warn).with(/fetch_error.*avatar too large/)
      expect(described_class.fetch("https://example.com/big.png")).to be_nil
    end

    it "returns nil and logs on connection refused / timeout" do
      stub_request(:get, "https://example.com/avatar.png").to_timeout
      expect(Rails.logger).to receive(:warn).with(/fetch_error/)
      expect(described_class.fetch("https://example.com/avatar.png")).to be_nil
    end

    it "returns nil and logs on HTTP 500" do
      stub_request(:get, "https://example.com/avatar.png")
        .to_return(status: 500, body: "boom")
      expect(Rails.logger).to receive(:warn).with(/fetch_error/)
      expect(described_class.fetch("https://example.com/avatar.png")).to be_nil
    end
  end
end

describe Jobs::ImportOauthAvatar do
  fab!(:user) { Fabricate(:user) }

  it "delegates to AvatarImporter when user exists" do
    expect(MultilingualPost::AvatarImporter)
      .to receive(:import_for)
      .with(user, "https://example.com/a.png")
    described_class.new.execute(user_id: user.id, avatar_url: "https://example.com/a.png")
  end

  it "no-ops when the user has been deleted" do
    user_id = user.id
    user.destroy!
    expect(MultilingualPost::AvatarImporter).not_to receive(:import_for)
    expect {
      described_class.new.execute(user_id: user_id, avatar_url: "https://example.com/a.png")
    }.not_to raise_error
  end
end
