require "./cache/*"

module Invidious::Cache
  extend self

  INSTANCE = self.init(CONFIG.cache)

  def init(cfg : Config::CacheConfig) : ItemStore
    # Environment variable takes precedence over local config
    url = ENV.fetch("INVIDIOUS_CACHE_URL", nil).try { |u| URI.parse(u) }
    url ||= cfg.url
    url ||= URI.new

    # Determine cache type from URL scheme
    type = StoreType.parse?(url.scheme || "none") || StoreType::None

    case type
    when .none?
      return NullItemStore.new
    when .redis?
      if url.nil?
        raise InvalidConfigException.new "Redis cache requires an URL."
      end
      return RedisItemStore.new(url)
    else
      raise InvalidConfigException.new "Invalid cache url. Only redis:// URL are currently supported."
    end
  end
end