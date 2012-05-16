require 'httpclient'
require 'cgi'
require 'multi_json'

require 'action_view/helpers/sanitize_helper'

module BentoSearch
  #
  # https://developers.google.com/books/docs/v1/using
  # https://developers.google.com/books/docs/v1/reference/volumes#resource  
  class GoogleBooksEngine
    include BentoSearch::SearchEngine
    include ActionView::Helpers::SanitizeHelper
    
    # class-level HTTPClient for maintaining persistent HTTP connections
    #class_attribute :http_client
    #self.http_client = HTTPClient.new
    
    class_attribute :base_url
    self.base_url = "https://www.googleapis.com/books/v1/"
    
    # used for testing only, GBS does allow some limited rate
    # of searches without a key. 
    class_attribute :suppress_key
    self.suppress_key = false
    
    
    def search(*arguments)
      arguments = parse_search_arguments(*arguments)
      
      query_url = args_to_search_url(arguments)

      results = Results.new

      begin
        http_client = HTTPClient.new
        response = http_client.get(query_url )
        json = MultiJson.load( response.body )
        # Can't rescue everything, or we catch VCR errors, making
        # things confusing. 
      rescue TimeoutError, HTTPClient::TimeoutError, 
            HTTPClient::ConfigurationError, HTTPClient::BadResponseError  => e
        results.error ||= {}
        results.error[:exception] = e
      end
            
      # Trap json parse error, but also check for bad http
      # status, or error reported in the json. In any of those cases
      # return results obj with error status. 
      #     
      if ( response.nil? || json.nil? || 
          (! HTTP::Status.successful? response.status) ||
          (json && json["error"]))

       results.error ||= {}
       results.error[:status] = response.status if response
       if json && json["error"] && json["error"]["errors"] && json["error"]["errors"].kind_of?(Array)
         results.error[:message] = json["error"]["errors"].first.values.join(", ")
       end
       results.error[:error_info] = json["error"] if json && json.respond_to?("[]")
       
       # escape early!
       return results
      end                        
      
      
      results.total_items = json["totalItems"]
      results.start = arguments[:start] || 0
      results.per_page = arguments[:per_page] || 10
      
      json["items"].each do |j_item|
        j_item = j_item["volumeInfo"] if j_item["volumeInfo"]
        
        item = ResultItem.new
        results << item
        
        item.title          = j_item["title"] 
        item.subtitle       = j_item["subtitle"] 
        item.link           = j_item["canonicalVolumeLink"]        
        item.abstract       = sanitize j_item["description"]        
        item.year_published = get_year j_item["publishedDate"]         
        item.format         = if j_item["printType"] == "MAGAZINE"
                              :serial
                            else
                              "Book"
                            end        
      end
      
      
      return results
    end
    
    
    protected
    
    
    ###########
    # BentoBox::SearchEngine API
    ###########
    
    def self.required_configuration
      ["api_key"]
    end
    
    def self.max_per_page
      100
    end
    
    def self.search_field_definitions
      { "intitle"     => {:semantic => :title},
        "inauthor"    => {:semantic => :author},
        "inpublisher" => {:semantic => :publisher},
        "subject"     => {:semantic => :subject},
        "isbn"        => {:semantic => :isbn}
      }      
    end
      
   
    
    #############
    # Our own implementation code
    ##############
    
    
    # takes a normalized #search arguments hash from SearchEngine
    # turns it into a URL for Google API. Factored out to make testing
    # possible. 
    def args_to_search_url(arguments)
      query = if arguments[:search_field]
        fielded_query(arguments[:query], arguments[:search_field])
      else
        arguments[:query]
      end
      
      query_url = base_url + "volumes?q=#{CGI.escape  query}"
      unless suppress_key
        query_url += "&key=#{configuration.api_key}"
      end
      
      if arguments[:per_page]
        query_url += "&maxResults=#{arguments[:per_page]}"
      end
      if arguments[:start]
        query_url += "&startIndex=#{arguments[:start]}"
      end
      
      return query_url
    end
    
    
    # If they ask for a <one two> :intitle, we're
    # actually gonna do like google's own form does,
    # and change it to <intitle:one intitle:two>. Internal
    # phrases will be respected. 
    def fielded_query(query, field)
      tokens = query.split(%r{\s|("[^"]+")}).delete_if {|a| a.blank?}
      return tokens.collect {|token| "#{field}:#{token}"}.join(" ")            
    end
    
    
    def get_year(iso8601)
      return nil if iso8601.blank?
      
      if iso8601 =~ /^(\d{4})/
        return $1.to_i
      end
      return nil            
    end
        
  end
end
