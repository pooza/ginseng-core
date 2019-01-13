require 'rexml/document'

module Ginseng
  class XMLRenderer < Renderer
    attr_accessor :message

    def type
      return 'application/xml; charset=UTF-8'
    end

    def to_s
      return xml.to_s
    end

    private

    def xml
      raise RequestError, 'message not defined' unless @message
      xml = REXML::Document.new
      xml.add(REXML::XMLDecl.new('1.0', 'UTF-8'))
      xml.add_element(REXML::Element.new('result'))
      message = xml.root.add_element('message')
      message.add_text(@message.to_s || 'error')
      return xml
    end
  end
end
