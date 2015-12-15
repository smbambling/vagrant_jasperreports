include stdlib

# Make sure PKI Certificates are installed before needed classes
Class['apache'] -> Sslmgmt::Cert <| |> -> Sslmgmt::Ca_dh <| |>

# Install *.example.dev Wildcard PKI certificate
$sslcerts = hiera(certs_for_system)
create_resources(sslmgmt::cert, $sslcerts)

# Install *.example.dev CA Certificate
$cacerts = hiera(ca_certs_for_system)
create_resources(sslmgmt::ca_dh, $cacerts)

$pki_keypair = '*.example.dev-server'

## Make sure that repositories are configured before packages are installed
  Yumrepo <| |> -> Package <| |>

 ## Required Repositories
 include yumrepo::pgdg_93

 # Include archive class to install required faraday gems
 include ::archive

 # Install/Configure PostgreSQL
 class { 'postgresql::globals':
   version  => '9.3',
   encoding => 'UTF8',
   locale   => 'en_US.UTF-8',
 }

class { 'postgresql::server':
  listen_addresses  => '*',
  port              => '5432',
  postgres_password => 'changeme',
} ->
# Install Java 1.8 for JasperReports Server
class { '::java':
  distribution => 'jre',
  package      => 'java-1.8.0-openjdk',
}->
# Install Tomcat version 8
class { 'tomcat': } ->
tomcat::instance{ 'default':
  source_url => 'http://repo1.maven.org/maven2/org/apache/tomcat/tomcat/8.0.23/tomcat-8.0.23.tar.gz',
}->
tomcat::config::server::tomcat_users { 'admin':
  roles    => [ 'manager-gui', ],
  password => 'password',
}->
class { '::jasperreports_server': } ->
file { 'tomcat8 init script':
  ensure => present,
  path   => '/etc/init.d/tomcat',
  owner  => root,
  group  => root,
  mode   => '0755',
  source => 'puppet:///modules/profile/jasperreports_server/tomcat_init',
} ->
tomcat::service { 'default': }

# Install Apache Front
class { 'apache':
  default_vhost    => false,
  default_ssl_cert => "/etc/pki/tls/certs/${pki_keypair}.crt",
  default_ssl_key  => "/etc/pki/tls/private/${pki_keypair}.key",
  default_ssl_ca   => '/etc/pki/tls/certs/example_dev_internal_ca.crt',
  trace_enable     => 'Off',
}

class { 'apache::mod::ssl':
  ssl_cipher   => 'HIGH:MEDIUM:!aNULL:!MD5',
  ssl_protocol => [ 'all', '-SSLv2', '-SSLv3' ],
}

class { 'apache::mod::status':
  allow_from      => [
    '127.0.0.1',
    '::1',
  ],
  extended_status => 'On',
  status_path     => '/server-status',
}

class { 'apache::mod::info':
  allow_from      => [
    '127.0.0.1',
    '::1',
  ],
  restrict_access => true,
}

class { 'apache::mod::proxy':
  proxy_requests => 'Off',
}

class { 'apache::mod::proxy_ajp': }

apache::vhost { "jasper.${::domain}":
  port                => '80',
  servername          => "jasper.${::domain}",
  serveraliases       => [ "jasper.${::domain}", $::fqdn ],
  docroot             => '/var/www/html',
  priority            => '25',
  default_vhost       => true,
  proxy_preserve_host => true,
  rewrites            => [
    {
      comment      => 'Don\'t Re-write /server-status or /server-info',
      rewrite_cond => ['%{REQUEST_URI} !=/server-info', '%{REQUEST_URI} !=/server-status'],
      rewrite_rule => ["^(.*)$ https://jasper.${::domain}/ [R=301,L]"],
    },
  ],
  directories         => [
    {
      path    => '/var/www/html',
      allow   => [
        'from 10.10.10.1',
        'from 127.0.0.1',
        'from ::1',
      ],
      options => [ 'Indexes','FollowSymLinks','MultiViews'],
    },
  ],
}

apache::vhost { "jasper.${::domain}-ssl":
  servername          => "jasper.${::domain}",
  serveraliases       => [ "jasper.${::domain}", $::fqdn ],
  port                => '443',
  docroot             => '/var/www/html',
  priority            => '25',
  ssl                 => true,
  proxy_preserve_host => true,
  ssl_cert            => "/etc/pki/tls/certs/${pki_keypair}.crt",
  ssl_key             => "/etc/pki/tls/private/${pki_keypair}.key",
  ssl_ca              => '/etc/pki/tls/certs/example_dev_internal_ca.crt',
  ssl_proxyengine     => true,
  rewrites            => [
    {
      comment      => 'Redirect to /jasperserver',
      rewrite_rule => ["^/$ https://jasper.${::domain}/jasperserver"],
    },
  ],
  headers             => [ 'set Access-Control-Allow-Origin "*"', ],
  proxy_pass          => [
    {
      'path'         => '/',
      'url'          => 'ajp://localhost:8009/',
      'reverse_urls' => [ 'ajp://localhost:8009/' ],
    },
  ],
}

