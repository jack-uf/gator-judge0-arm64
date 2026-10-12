module Base64Service
  def self.encode(text)
    return nil unless text
    Base64.strict_encode64(text.to_s)
  end

  def self.decode(text)
    return nil unless text
    decoded = Base64.decode64(text.to_s)
    clean_utf8(decoded)
  rescue Exception
    text
  end

  # `additional_files` carries a zip: raw binary whose header bytes (sizes,
  # CRCs, offsets) are arbitrary. It must NOT go through clean_utf8, which
  # replaces every byte that is not valid UTF-8 with "?" (0x3f) and silently
  # rewrites those header fields, so unzip reads a truncated file and the
  # compile fails on a header the student did include. Text fields keep the
  # clean_utf8 path above; binary payloads come through here instead.
  def self.decode_binary(text)
    return nil unless text
    Base64.decode64(text.to_s).force_encoding(Encoding::BINARY)
  end

  def self.clean_utf8(text)
    return nil if text.nil?
    str = text.to_s.dup
    str.force_encoding("UTF-8")
    return str if str.valid_encoding?
    # Not valid UTF-8, so return the bytes untranslated rather than encoding them
    # with a replacement character. Replacing turned every byte that is not valid
    # UTF-8 into "?", which made all such bytes equal to each other: a program
    # printing 0xFE compared equal to one printing 0xFF, so a wrong answer could
    # be reported as Accepted. Tagged binary means the bytes compare as bytes,
    # which is what the other side of the comparison is: a raw read of the
    # sandbox's stdout file.
    str.force_encoding(Encoding::BINARY)
  end
end
