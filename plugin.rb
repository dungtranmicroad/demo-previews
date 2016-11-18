# name: discourse-topic-previews
# about: A Discourse plugin that gives you a topic preview image in the topic list
# version: 0.2
# authors: Angus McLeod

register_asset 'stylesheets/previews_common.scss', :desktop
register_asset 'stylesheets/previews_mobile.scss'

after_initialize do

  Category.register_custom_field_type('list_thumbnails', :boolean)
  Category.register_custom_field_type('list_excerpts', :boolean)
  Category.register_custom_field_type('list_actions', :boolean)
  Category.register_custom_field_type('list_category_badge_move', :boolean)
  Topic.register_custom_field_type('thumbnails', :json)

  @nil_thumbs = TopicCustomField.where( name: 'thumbnails', value: nil )
  if @nil_thumbs.length
    @nil_thumbs.each do |thumb|
      hash = { :normal => '', :retina => ''}
      thumb.value = ::JSON.generate(hash)
      thumb.save!
    end
  end

  module ListHelper
    class << self
      def create_thumbnails(id, image, original_url)
        width = SiteSetting.topic_list_thumbnail_width
        height = SiteSetting.topic_list_thumbnail_height
        normal = image ? thumbnail_url(image, width, height, original_url) : original_url
        retina = image ? thumbnail_url(image, width*2, height*2, original_url) : original_url
        thumbnails = { normal: normal, retina: retina }
        save_thumbnails(id, thumbnails)
        return thumbnails
      end

      def thumbnail_url (image, w, h, original_url)
        image.create_thumbnail!(w, h) if !image.has_thumbnail?(w, h)
        image.has_thumbnail?(w, h) ? image.thumbnail(w, h).url : original_url
      end

      def save_thumbnails(id, thumbnails)
        return if !thumbnails
        topic = Topic.find(id)
        topic.custom_fields['thumbnails'] = thumbnails
        topic.save_custom_fields
      end
    end
  end

  require 'cooked_post_processor'
  class ::CookedPostProcessor

    def get_linked_image(url)
      max_size = SiteSetting.max_image_size_kb.kilobytes
      file = FileHelper.download(url, max_size, "discourse", true) rescue nil
      Rails.logger.info "Downloaded linked image: #{file}"
      image = file ? Upload.create_for(@post.user_id, file, file.path.split('/')[-1], File.size(file.path)) : nil
      image
    end

    def create_topic_thumbnails(url)
      local = UrlHelper.is_local(url)
      image = local ? Upload.find_by(sha1: url[/[a-z0-9]{40,}/i]) : get_linked_image(url)
      Rails.logger.info "Creating thumbnails with: #{image}"
      ListHelper.create_thumbnails(@post.topic.id, image, url)
    end

    def update_post_image
      img = extract_images_for_post.first
      if img["src"].present?
        @post.update_column(:image_url, img["src"][0...255]) # post
        if @post.is_first_post?
          @post.topic.update_column(:image_url, img["src"][0...255]) # topic
          return if SiteSetting.topic_list_hotlink_thumbnails
          create_topic_thumbnails(url)
        end
      end
    end

  end

  require 'topic_list_item_serializer'
  class ::TopicListItemSerializer
    attributes :thumbnails,
               :topic_post_id,
               :topic_post_liked,
               :topic_post_like_count,
               :topic_post_can_like,
               :topic_post_can_unlike,
               :topic_post_bookmarked,
               :topic_post_is_current_users

    def first_post_id
     first = Post.find_by(topic_id: object.id, post_number: 1)
     first ? first.id : false
    end

    def topic_post_id
      accepted_id = object.custom_fields["accepted_answer_post_id"].to_i
      return accepted_id > 0 ? accepted_id : first_post_id
    end
    alias :include_topic_post_id? :first_post_id

    def excerpt
      cooked = Post.where(id: topic_post_id).pluck('cooked')
      excerpt = PrettyText.excerpt(cooked[0], SiteSetting.topic_list_excerpt_length, keep_emoji_images: true)
      excerpt.gsub!(/(\[#{I18n.t 'excerpt_image'}\])/, "") if excerpt
      excerpt
    end

    def include_excerpt?
      object.excerpt.present?
    end

    def thumbnails
      return unless object.archetype == Archetype.default
      if SiteSetting.topic_list_hotlink_thumbnails
        thumbs = { normal: object.image_url, retina: object.image_url }
      else
        thumbs = get_thumbnails || get_thumbnails_from_image_url || to_html || placeholder_html ||  data ||  generic_html ||  is_image? ||  has_image? || is_video? || is_embedded? || image_html || video_html || 
      end
      thumbs
    end

    def include_thumbnails?
      thumbnails.present? && (thumbnails[:normal].present? || thumbnails['normal'].present?)
    end

    def get_thumbnails
      thumbnails = object.custom_fields['thumbnails']
      if thumbnails.is_a?(String)
        thumbnails = ::JSON.parse(thumbnails)
      end
      if thumbnails.is_a?(Array)
        thumbnails = thumbnails[0]
      end
      thumbnails.is_a?(Hash) ? thumbnails : false
    end

    def get_thumbnails_from_image_url
      image = Upload.get_from_url(object.image_url) rescue false
      return ListHelper.create_thumbnails(object.id, image, object.image_url)
    end  
    
    def topic_post_actions
      return [] if !scope.current_user
      PostAction.where(post_id: topic_post_id, user_id: scope.current_user.id)
    end

    def topic_like_action
      topic_post_actions.select {|a| a.post_action_type_id == PostActionType.types[:like]}
    end

    def topic_post
      Post.find(topic_post_id)
    end

    def topic_post_bookmarked
      !!topic_post_actions.any?{|a| a.post_action_type_id == PostActionType.types[:bookmark]}
    end
    alias :include_topic_post_bookmarked? :first_post_id

    def topic_post_liked
      topic_like_action.any?
    end
    alias :include_topic_post_liked? :first_post_id

    def topic_post_like_count
      topic_post.like_count
    end
    alias :include_topic_post_like_count? :first_post_id

    def include_topic_post_like_count?
      first_post_id && topic_post_like_count > 0
    end

    def topic_post_can_like
      post = topic_post
      return false if !scope.current_user || topic_post_is_current_users
      scope.post_can_act?(post, PostActionType.types[:like], taken_actions: topic_post_actions)
    end
    alias :include_topic_post_can_like? :first_post_id

    def topic_post_is_current_users
      return scope.current_user && (topic_post.user_id == scope.current_user.id)
    end
    alias :include_topic_post_is_current_users? :first_post_id

    def topic_post_can_unlike
      return false if !scope.current_user
      action = topic_like_action[0]
      !!(action && (action.user_id == scope.current_user.id) && (action.created_at > SiteSetting.post_undo_action_window_mins.minutes.ago))
    end
    alias :include_topic_post_can_unlike? :first_post_id

  end

  TopicList.preloaded_custom_fields << "accepted_answer_post_id" if TopicList.respond_to? :preloaded_custom_fields
  TopicList.preloaded_custom_fields << "thumbnails" if TopicList.respond_to? :preloaded_custom_fields

  add_to_serializer(:basic_category, :list_excerpts) {object.custom_fields["list_excerpts"]}
  add_to_serializer(:basic_category, :list_thumbnails) {object.custom_fields["list_thumbnails"]}
  add_to_serializer(:basic_category, :list_actions) {object.custom_fields["list_actions"]}
  add_to_serializer(:basic_category, :list_category_badge_move) {object.custom_fields["list_category_badge_move"]}
  add_to_serializer(:basic_category, :list_default_thumbnail) {object.custom_fields["list_default_thumbnail"]}
end




require 'htmlentities'

module Onebox
  module Engine
    class WhitelistedGenericOnebox
      include Engine
      include StandardEmbed
      include LayoutSupport

      def self.whitelist=(list)
        @whitelist = list
      end

      def self.whitelist
        @whitelist ||= default_whitelist.dup
      end

      def self.default_whitelist
        %w(
          23hq.com
          500px.com
          8tracks.com
          abc.net.au
          about.com
          answers.com
          arstechnica.com
          ask.com
          battle.net
          bbc.co.uk
          bbs.boingboing.net
          bestbuy.ca
          bestbuy.com
          blip.tv
          bloomberg.com
          businessinsider.com
          change.org
          clikthrough.com
          cnet.com
          cnn.com
          codepen.io
          collegehumor.com
          consider.it
          coursera.org
          cracked.com
          dailymail.co.uk
          dailymotion.com
          deadline.com
          dell.com
          deviantart.com
          digg.com
          dotsub.com
          ebay.ca
          ebay.co.uk
          ebay.com
          ehow.com
          espn.go.com
          etsy.com
          findery.com
          flickr.com
          folksy.com
          forbes.com
          foxnews.com
          funnyordie.com
          gfycat.com
          groupon.com
          howtogeek.com
          huffingtonpost.ca
          huffingtonpost.com
          hulu.com
          ign.com
          ikea.com
          imdb.com
          indiatimes.com
          instagr.am
          instagram.com
          itunes.apple.com
          khanacademy.org
          kickstarter.com
          kinomap.com
          lessonplanet.com
          liveleak.com
          livestream.com
          mashable.com
          medium.com
          meetup.com
          mixcloud.com
          mlb.com
          myshopify.com
          myspace.com
          nba.com
          npr.org
          nytimes.com
          photobucket.com
          pinterest.com
          reference.com
          revision3.com
          rottentomatoes.com
          samsung.com
          screenr.com
          scribd.com
          slideshare.net
          sourceforge.net
          speakerdeck.com
          spotify.com
          squidoo.com
          techcrunch.com
          ted.com
          thefreedictionary.com
          theglobeandmail.com
          thenextweb.com
          theonion.com
          thestar.com
          thesun.co.uk
          thinkgeek.com
          tmz.com
          torontosun.com
          tumblr.com
          twitch.tv
          twitpic.com
          usatoday.com
          viddler.com
          videojug.com
          vimeo.com
          vine.co
          walmart.com
          washingtonpost.com
          wi.st
          wikia.com
          wikihow.com
          wired.com
          wistia.com
          wonderhowto.com
          wsj.com
          zappos.com
          zillow.com
        )
      end

      # Often using the `html` attribute is not what we want, like for some blogs that
      # include the entire page HTML. However for some providers like Flickr it allows us
      # to return gifv and galleries.
      def self.default_html_providers
        ['Flickr', 'Meetup']
      end

      def self.html_providers
        @html_providers ||= default_html_providers.dup
      end

      def self.html_providers=(new_provs)
        @html_providers = new_provs
      end

      # A re-written URL converts http:// -> https://
      def self.rewrites
        @rewrites ||= https_hosts.dup
      end

      def self.rewrites=(new_list)
        @rewrites = new_list
      end

      def self.https_hosts
        %w(slideshare.net dailymotion.com livestream.com)
      end

      def self.host_matches(uri, list)
        !!list.find {|h| %r((^|\.)#{Regexp.escape(h)}$).match(uri.host) }
      end

      def self.probable_discourse(uri)
        !!(uri.path =~ /\/t\/[^\/]+\/\d+(\/\d+)?(\?.*)?$/)
      end

      def self.probable_wordpress(uri)
        !!(uri.path =~ /\d{4}\/\d{2}\//)
      end

      def self.===(other)
        if other.kind_of?(URI)
          host_matches(other, whitelist) || probable_wordpress(other) || probable_discourse(other)
        else
          super
        end
      end

      def to_html
        rewrite_https(generic_html)
      end

      def placeholder_html
        return article_html if is_article?
        return image_html   if has_image? && (is_video? || is_image?)
        return article_html if has_text? && is_embedded?
        to_html
      end

      def data
        @data ||= begin
          html_entities = HTMLEntities.new
          d = { link: link }.merge(raw)
          if !Onebox::Helpers.blank?(d[:title])
            d[:title] = html_entities.decode(Onebox::Helpers.truncate(d[:title]))
          end
          if !Onebox::Helpers.blank?(d[:description])
            d[:description] = html_entities.decode(Onebox::Helpers.truncate(d[:description], 250))
          end
          d
        end
      end

      private

        def rewrite_https(html)
          return unless html
          uri = URI(@url)
          html.gsub!("http://", "https://") if WhitelistedGenericOnebox.host_matches(uri, WhitelistedGenericOnebox.rewrites)
          html
        end

        def generic_html
          return article_html  if is_article?
          return video_html    if is_video?
          return image_html    if is_image?
          return article_html  if has_text?
          return embedded_html if is_embedded?
        end

        def is_article?
          data[:type] =~ /article/ &&
          has_text?
        end

        def has_text?
          !Onebox::Helpers.blank?(data[:title]) &&
          !Onebox::Helpers.blank?(data[:description])
        end

        def is_image?
          data[:type] =~ /photo|image/ &&
          data[:type] !~ /photostream/ &&
          has_image?
        end

        def has_image?
          !Onebox::Helpers.blank?(data[:image]) ||
          !Onebox::Helpers.blank?(data[:thumbnail_url])
        end

        def is_video?
          data[:type] =~ /video/ &&
          !Onebox::Helpers.blank?(data[:video])
        end

        def is_embedded?
          data[:html] &&
          (
            data[:html]["iframe"] ||
            WhitelistedGenericOnebox.html_providers.include?(data[:provider_name])
          )
        end

        def article_html
          layout.to_html
        end

        def image_html
          src = data[:image] || data[:thumbnail_url]
          return if Onebox::Helpers.blank?(src)

          alt    = data[:description]  || data[:title]
          width  = data[:image_width]  || data[:thumbnail_width]
          height = data[:image_height] || data[:thumbnail_height]
          "<img src='#{src}' alt='#{alt}' width='#{width}' height='#{height}'>"
        end

        def video_html
          if data[:video_type] == "video/mp4"
            <<-HTML
              <video title='#{data[:title]}'
                     width='#{data[:video_width]}'
                     height='#{data[:video_height]}'
                     style='max-width:100%'
                     controls=''>
                <source src='#{data[:video]}'>
              </video>
            HTML
          else
            <<-HTML
              <iframe src='#{data[:video]}'
                      title='#{data[:title]}'
                      width='#{data[:video_width]}'
                      height='#{data[:video_height]}'
                      frameborder='0'>
              </iframe>
            HTML
          end
        end

        def embedded_html
          fragment = Nokogiri::HTML::fragment(data[:html])
          fragment.css("img").each { |img| img["class"] = "thumbnail" }
          fragment.to_html
        end
    end
  end
end
