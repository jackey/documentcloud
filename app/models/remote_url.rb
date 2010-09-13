class RemoteUrl < ActiveRecord::Base

  self.establish_connection(ANALYTICS_DB)

  named_scope :aggregated, {
    :select => 'sum(hits) AS hits, document_id, url',
    :group => 'document_id, url'
  }

  def self.record_hits(doc_id, url, hits)
    row = self.find_or_create_by_document_id_and_url_and_date_recorded(doc_id, url, Time.now.utc.to_date)
    row.update_attributes :hits => row.hits + hits
  end

  # Using the recorded remote URL hits, correctly set detected remote urls
  # for all documents. This method is only ever run within a background job.
  def self.set_all_detected_remote_urls!
    urls = self.aggregated.all
    top  = urls.inject({}) do |memo, url|
      id = url.document_id
      memo[id] = url if !memo[id] || memo[id].hits < url.hits
      memo
    end
    Document.find_each(:conditions => {:id => top.keys}) do |doc|
      doc.detected_remote_url = top[doc.id].url
      doc.save if doc.changed?
    end
  end

  def self.top_documents(days=7, options={})
    urls = self.aggregated.all({
      :conditions => ['date_recorded > ?', days.days.ago],
      :having => ['sum(hits) > 0'],
      :order => 'hits desc'
    }.merge(options))
    docs = Document.find_all_by_id(urls.map {|u| u.document_id }).inject({}) do |memo, doc|
      memo[doc.id] = doc
      memo
    end
    urls.select {|url| !!docs[url.document_id] }.map do |url|
      url_attrs = url.attributes
      url_attrs[:id] = "#{url.document_id}:#{url.url}"
      first_hit = RemoteUrl.first(:select => 'created_at',
                                  :conditions => {:document_id => url['document_id']},
                                  :order => 'created_at ASC')
      url_attrs[:first_recorded_date] = first_hit[:created_at].strftime "%a %b %d, %Y"
      docs[url.document_id].admin_attributes.merge(url_attrs)
    end
  end

end