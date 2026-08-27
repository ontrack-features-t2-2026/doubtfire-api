# Use Rails' configured cache for Rack::Attack.
Rack::Attack.cache.store = Rails.cache

# Limit authentication attempts from a single IP.
Rack::Attack.throttle('auth/ip', limit: 5, period: 1.minute) do |req|
  req.ip if req.post? && req.path.match?(%r{\A/api/auth(?:\.json)?\z})
end

# Limit attempts against a single username.
Rack::Attack.throttle('auth/username', limit: 5, period: 1.minute) do |req|
  if req.post? && req.path.match?(%r{\A/api/auth(?:\.json)?\z})
    req.params['username'].to_s.downcase.strip.presence
  end
end
