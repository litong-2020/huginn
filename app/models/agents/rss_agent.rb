module Agents
  class RssAgent < Agent
    include WebRequestConcern

    cannot_receive_events!
    can_dry_run!
    default_schedule "every_1d"

    gem_dependency_check { defined?(Feedjira::Feed) }

    DEFAULT_EVENTS_ORDER = [['{{date_published}}', 'time'], ['{{last_updated}}', 'time']]

    description do
      <<-MD
        The RSS Agent consumes RSS feeds and emits events when they change.

        This agent, using [Feedjira](https://github.com/feedjira/feedjira) as a base, can parse various types of RSS and Atom feeds and has some special handlers for FeedBurner, iTunes RSS, and so on.  However, supported fields are limited by its general and abstract nature.  For complex feeds with additional field types, we recommend using a WebsiteAgent.  See [this example](https://github.com/cantino/huginn/wiki/Agent-configuration-examples#itunes-trailers).

        If you want to *output* an RSS feed, use the DataOutputAgent.

        Options:

          * `url` - The URL of the RSS feed (an array of URLs can also be used; items with identical guids across feeds will be considered duplicates).
          * `include_feed_info` - Set to `true` to include feed information in each event.
          * `clean` - Set to `true` to sanitize `description` and `content` as HTML fragments, removing unknown/unsafe elements and attributes.
          * `expected_update_period_in_days` - How often you expect this RSS feed to change.  If more than this amount of time passes without an update, the Agent will mark itself as not working.
          * `headers` - When present, it should be a hash of headers to send with the request.
          * `basic_auth` - Specify HTTP basic auth parameters: `"username:password"`, or `["username", "password"]`.
          * `disable_ssl_verification` - Set to `true` to disable ssl verification.
          * `disable_url_encoding` - Set to `true` to disable url encoding.
          * `force_encoding` - Set `force_encoding` to an encoding name if the website is known to respond with a missing, invalid or wrong charset in the Content-Type header.  Note that a text content without a charset is taken as encoded in UTF-8 (not ISO-8859-1).
          * `user_agent` - A custom User-Agent name (default: "Faraday v#{Faraday::VERSION}").
          * `max_events_per_run` - Limit number of events created (items parsed) per run for feed.

        # Ordering Events

        #{description_events_order}

        In this Agent, the default value for `events_order` is `#{DEFAULT_EVENTS_ORDER.to_json}`.
      MD
    end

    def default_options
      {
        'expected_update_period_in_days' => "5",
        'clean' => 'false',
        'url' => "https://github.com/cantino/huginn/commits/master.atom"
      }
    end

    event_description <<-MD
      Events look like:

          {
            "feed": {
              "id": "...",
              "type": "atom",
              "generator": "...",
              "url": "http://example.com/",
              "links": [
                { "href": "http://example.com/", "rel": "alternate", "type": "text/html" },
                { "href": "http://example.com/index.atom", "rel": "self", "type": "application/atom+xml" }
              ],
              "title": "Some site title",
              "description": "Some site description",
              "copyright": "...",
              "icon": "http://example.com/icon.png",
              "authors": [ "..." ],
              "date_published": "2014-09-11T01:30:00-07:00",
              "last_updated": "2014-09-11T01:30:00-07:00"
            },
            "id": "829f845279611d7925146725317b868d",
            "url": "http://example.com/...",
            "urls": [ "http://example.com/..." ],
            "links": [
              { "href": "http://example.com/...", "rel": "alternate" },
            ],
            "title": "Some title",
            "description": "Some description",
            "content": "Some content",
            "authors": [ "Some Author <email@address>" ],
            "categories": [ "..." ],
            "image": "http://example.com/...",
            "enclosure": {
              "url" => "http://example.com/file.mp3", "type" => "audio/mpeg", "length" => "123456789"
            },
            "date_published": "2014-09-11T01:30:00-0700",
            "last_updated": "2014-09-11T01:30:00-0700"
          }

      Some notes:

      - The `feed` key is present only if `include_feed_info` is set to true.
      - Each element in `authors` is a string normalized in the format "*name* <*email*> (*url*)", where each space-separated part is optional.
      - Timestamps are converted to the ISO 8601 format.
    MD

    def working?
      event_created_within?((interpolated['expected_update_period_in_days'].presence || 10).to_i) && !recent_error_logs?
    end

    def validate_options
      errors.add(:base, "url is required") unless options['url'].present?

      unless options['expected_update_period_in_days'].present? && options['expected_update_period_in_days'].to_i > 0
        errors.add(:base, "Please provide 'expected_update_period_in_days' to indicate how many days can pass without an update before this Agent is considered to not be working")
      end

      validate_web_request_options!
      validate_events_order
    end

    def events_order(key = SortableEvents::EVENTS_ORDER_KEY)
      if key == SortableEvents::EVENTS_ORDER_KEY
        super.presence || DEFAULT_EVENTS_ORDER
      else
        raise ArgumentError, "unsupported key: #{key}"
      end
    end

    def check
      check_urls(Array(interpolated['url']))
    end

    protected

    def check_urls(urls)
      new_events = []
      max_events = (interpolated['max_events_per_run'].presence || 0).to_i

      urls.each do |url|
        begin
          response = faraday.get(url)
          if response.success?
            feed = Feedjira::Feed.parse(preprocessed_body(response))
            new_events.concat feed_to_events(feed)
          else
            error "Failed to fetch #{url}: #{response.inspect}"
          end
        rescue => e
          error "Failed to fetch #{url} with message '#{e.message}': #{e.backtrace}"
        end
      end

      created_event_count = 0
      sort_events(new_events).each.with_index do |event, index|
        entry_id = event.payload[:id]
        if check_and_track(entry_id)
          unless max_events && max_events > 0 && index >= max_events
            created_event_count += 1
            create_event(event)
          end
        end
      end
      log "Fetched #{urls.to_sentence} and created #{created_event_count} event(s)."
    end

    def check_and_track(entry_id)
      memory['seen_ids'] ||= []
      if memory['seen_ids'].include?(entry_id)
        false
      else
        memory['seen_ids'].unshift entry_id
        memory['seen_ids'].pop if memory['seen_ids'].length > 500
        true
      end
    end

    unless dependencies_missing?
      require 'feedjira_extension'
    end

    def preprocessed_body(response)
      body = response.body
      case body.encoding
      when Encoding::ASCII_8BIT
        # Encoding is unknown from the Content-Type, so let the SAX
        # parser detect it from the content.
      else
        # Encoding is already known, so do not let the parser detect
        # it from the XML declaration in the content.
        body.sub!(/(\A\u{FEFF}?\s*<\?xml(?:\s+\w+\s*=\s*(['"]).*?\2)*)\s+encoding\s*=\s*(['"]).*?\3/, '\\1')
      end
      body
    end

    def feed_data(feed)
      type =
        case feed.class.name
        when /Atom/
          'atom'
        else
          'rss'
        end

      {
        id: feed.feed_id,
        type: type,
        url: feed.url,
        links: feed.links,
        title: feed.title,
        description: feed.description,
        copyright: feed.copyright,
        generator: feed.generator,
        icon: feed.icon,
        authors: feed.authors,
        date_published: feed.date_published,
        last_updated: feed.last_updated,
      }
    end

    def entry_data(entry)
      {
        id: entry.id,
        url: entry.url,
        urls: entry.links.map(&:href),
        links: entry.links,
        title: entry.title,
        description: clean_fragment(entry.summary),
        content: clean_fragment(entry.content || entry.summary),
        image: entry.try(:image),
        enclosure: entry.enclosure,
        authors: entry.authors,
        categories: Array(entry.try(:categories)),
        date_published: entry.date_published,
        last_updated: entry.last_updated,
      }
    end

    def feed_to_events(feed)
      payload_base = {}

      if boolify(interpolated['include_feed_info'])
        payload_base[:feed] = feed_data(feed)
      end

      feed.entries.map { |entry|
        Event.new(payload: payload_base.merge(entry_data(entry)))
      }
    end

    def clean_fragment(fragment)
      if boolify(interpolated['clean']) && fragment.present?
        Loofah.scrub_fragment(fragment, :prune).to_s
      else
        fragment
      end
    end
  end
end
