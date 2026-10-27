# VPS host nginx

The host's `/etc/nginx/sites-enabled/rakuen-estate.conf` serves every public
name from one vhost per protocol. For smoothapt:

1. `map $host $backend`: `updates.rakuensoftware.com  10.1.0.252:80;`
2. Add `updates.rakuensoftware.com` to both `server_name` lists.
3. Once the DNS record points at the VPS: issue the certificate (as for the
   other names), then add the name to `map $host $force_https`. Credentials
   must only ever travel over HTTPS; until this step the `/smoothrouter`
   archive is not to be used by clients.
