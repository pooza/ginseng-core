module Ginseng
  class VideoURI < URI
    include Package

    def initialize(options = {})
      super(options)
      @service = you_tube_service_class.new
    end

    def id
      return query_values['v']
    rescue
      return nil
    end

    def data
      @data ||= @service.lookup_video(id)
      return @data
    end

    def title
      return nil unless data
      return data['snippet']['title']
    end

    def count
      return nil unless data
      return data['statistics']['viewCount'].to_i
    end
  end
end
