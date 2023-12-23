# Mapping of subdomain => YoutubeConnectionPool
# This is needed as we may need to access arbitrary subdomains of ytimg
private YTIMG_POOLS = {} of String => YoutubeConnectionPool

struct YoutubeConnectionPool
  property! url : URI
  property! capacity : Int32
  property! timeout : Float64
  property pool : DB::Pool(HTTP::Client)

  def initialize(url : URI, @capacity = 5, @timeout = 5.0)
    @url = url
    @pool = build_pool()
  end

  def client(region = nil, &block)
    if region
      conn = make_client(url, region, force_resolve = true)
      response = yield conn
    else
      conn = pool.checkout
      begin
        response = yield conn
      rescue ex
        conn.close
        conn = HTTP::Client.new(url)

        conn.family = CONFIG.force_resolve
        conn.family = Socket::Family::INET if conn.family == Socket::Family::UNSPEC
        conn.before_request { |r| add_yt_headers(r) } if url.host == "www.youtube.com"
        response = yield conn
      ensure
        pool.release(conn)
      end
    end

    response
  end

  private def build_pool
    DB::Pool(HTTP::Client).new(initial_pool_size: 0, max_pool_size: capacity, max_idle_pool_size: capacity, checkout_timeout: timeout) do
      conn = HTTP::Client.new(url)
      conn.family = CONFIG.force_resolve
      conn.family = Socket::Family::INET if conn.family == Socket::Family::UNSPEC
      conn.before_request { |r| add_yt_headers(r) } if url.host == "www.youtube.com"
      conn
    end
  end
end

def add_yt_headers(request)
  request.headers.delete("User-Agent") if request.headers["User-Agent"] == "Crystal"
  request.headers["User-Agent"] ||= "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/114.0.0.0 Safari/537.36"

  request.headers["Accept-Charset"] ||= "ISO-8859-1,utf-8;q=0.7,*;q=0.7"
  request.headers["Accept"] ||= "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
  request.headers["Accept-Language"] ||= "en-us,en;q=0.5"

  # Preserve original cookies and add new YT consent cookie for EU servers
  request.headers["Cookie"] = "#{request.headers["cookie"]?}; CONSENT=PENDING+#{Random.rand(100..999)}"
  if !CONFIG.cookies.empty?
    request.headers["Cookie"] = "#{(CONFIG.cookies.map { |c| "#{c.name}=#{c.value}" }).join("; ")}; #{request.headers["cookie"]?}"
  end
end

def make_client(url : URI, region = nil, force_resolve : Bool = false)
  client = HTTPClient.new(url, OpenSSL::SSL::Context::Client.insecure)

  # Some services do not support IPv6.
  if force_resolve
    client.family = CONFIG.force_resolve
  end

  client.before_request { |r| add_yt_headers(r) } if url.host == "www.youtube.com"
  client.read_timeout = 10.seconds
  client.connect_timeout = 10.seconds

  if region
    PROXY_LIST[region]?.try &.sample(40).each do |proxy|
      begin
        proxy = HTTPProxy.new(proxy_host: proxy[:ip], proxy_port: proxy[:port])
        client.set_proxy(proxy)
        break
      rescue ex
      end
    end
  end

  return client
end

def make_client(url : URI, region = nil, force_resolve : Bool = false, &block)
  client = make_client(url, region, force_resolve)
  begin
    yield client
  ensure
    client.close
  end
end

# Fetches a HTTP pool for the specified subdomain of ytimg.com
#
# Creates a new one when the specified pool for the subdomain does not exist
def get_ytimg_pool(subdomain)
  if pool = YTIMG_POOLS[subdomain]?
    return pool
  else
    LOGGER.info("ytimg_pool: Creating a new HTTP pool for \"https://#{subdomain}.ytimg.com\"")
    pool = YoutubeConnectionPool.new(URI.parse("https://#{subdomain}.ytimg.com"), capacity: CONFIG.pool_size)
    YTIMG_POOLS[subdomain] = pool

    return pool
  end
end
