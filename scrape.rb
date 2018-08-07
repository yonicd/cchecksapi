require "faraday"
require 'typhoeus'
require 'typhoeus/adapters/faraday'
require "parallel"
require "multi_json"
require "oga"
require "mongo"

require_relative 'utils'

# mongo_host = [ ENV.fetch('MONGO_PORT_27017_TCP_ADDR') + ":" + ENV.fetch('MONGO_PORT_27017_TCP_PORT') ]
client_options = {
  :database => 'cchecksdb',
  :user => ENV.fetch('CCHECKS_MONGO_USER'),
  :password => ENV.fetch('CCHECKS_MONGO_PWD'),
  :max_pool_size => 25,
  :connect_timeout => 15,
  :wait_queue_timeout => 15
}
# $mongo = Mongo::Client.new(mongo_host, client_options)
$mongo = Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'cchecksdb')
$cks = $mongo[:checks]

def scrape_all
  pkgs = cran_packages;
  resp_onses = async_get(pkgs);
  out = Parallel.map(resp_onses, in_processes: 4) { |e| scrape_pkg_body(e) };
  if $cks.count > 0
    $cks.drop
    $cks = $mongo[:checks]
  end
  $cks.insert_many(out.map { |e| prep_mongo(e) })
end

def prep_mongo(x)
  x.merge!({'_id' => x["package"]})
  x.merge!({'date_updated' => DateTime.now.to_time.utc})
  return x
end

class Array
  def count_em(x)
    return self.find_all { |z| z == x }.count
  end
end

def scrape_pkg_body(z)
  base_url = 'https://cran.rstudio.com/web/checks/check_results_%s.html'
  pkg = z.to_hash[:url].to_s.sub('https://cran.rstudio.com/web/checks/check_results_', '').sub('.html', '')
  if !z.success?
    return {"package" => pkg, "checks" => nil}
  end

  html = Oga.parse_html(z.body)
  tr = html.xpath('//table//tr');
  rws = tr.map { |e| e.xpath('./td//text()').map { |w| w.text }  }.keep_if { |a| a.length > 0 }
  rws = rws.map { |e| e.map { |f| f.lstrip } }
  rws = rws.map { |e| [e[2], e[3], e[4], e[5], e[6], e[9]] }
  nms = tr[0].text.split(' ')
  nms.pop
  res = rws.map { |e| Hash[nms.zip(e)] }

  # get urls and join to dataset
  hrefs = fetch_urls(tr)
  hrefs.each_with_index do |val, i|
    res[i].merge!({"check_url" => hrefs[i]})
  end

  # lowercase all keys
  res.map { |a| a.keys.map { |k| a[k.downcase] = a.delete k } }
  # strip all whitespace
  res.map { |a| a.map { |k, v| a[k] = v.strip } }
  # numbers are numbers
  res.map { |a| a.map { |k, v| a[k] = v.to_f if k.match(/tinstall|tcheck|ttotal/) } }

  # make summary
  stats = res.map { |a| a['status'] }.map(&:downcase)
  summary = {
    "any" => stats.count_em("ok") != stats.length,
    "ok" => stats.count_em("ok"), 
    "note" => stats.count_em("note"), 
    "warn" => stats.count_em("warn"), 
    "error"=> stats.count_em("error")
  }

  return {"package" => pkg, "url" => base_url % pkg, "summary" => summary, "checks" => res}
end

def fetch_urls(foo)
  tmp = foo.map { |e| e.xpath('./td//a[contains(., "OK") or contains(., "ERROR") or contains(., "NOTE")]') }
  tmp = tmp.keep_if { |e| e.length > 0 }
  xx = tmp.map { |e| e.attribute('href')[0].text }
  return xx
end

# ro_packages()
def ro_packages
  conn = Faraday.new(:url => 'https://raw.githubusercontent.com/ropensci/roregistry/master/registry.json') do |f|
    f.adapter Faraday.default_adapter
  end
  x = conn.get
  out = MultiJson.load(x.body)
  pkgs = out['packages'].collect { |x| x['name'] }
  return pkgs
end

def cran_packages
  $crandb_conn = Faraday.new(:url => "https://crandb.r-pkg.org") do |f|
    f.adapter Faraday.default_adapter
  end
  # new
  x = $crandb_conn.get "/-/pkgnames";
  out = MultiJson.load(x.body)
  return out.keys.uniq
end
