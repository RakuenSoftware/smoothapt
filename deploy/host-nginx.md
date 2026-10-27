# VPS host nginx

The host's `/etc/nginx/sites-enabled/rakuen-estate.conf` serves every public
name from one vhost per protocol. smoothapt shares the port-80 block (ACME and
the HTTPS redirect) but has its own HTTPS server block, because it asks for
client certificates and no other site may:

1. `map $host $backend`: `updates.rakuensoftware.com  10.1.0.252:80;` and
   `map $host $force_https`: `updates.rakuensoftware.com 1;`
2. Add `updates.rakuensoftware.com` to the port-80 `server_name` list only, and
   to the `estate` certificate.
3. Copy the client CA certificate out of the container:
   `incus file pull ct252/etc/smoothapt/ca/ca.crt /etc/nginx/smoothapt-client-ca.pem`
4. Add this server block:

```nginx
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name updates.rakuensoftware.com;

    ssl_certificate     /etc/letsencrypt/live/estate/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/estate/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;

    # Users' certificates (smoothapt-user). Optional: the public archive is
    # open to anyone; ct252 refuses /smoothrouter/ without a verified one.
    ssl_client_certificate /etc/nginx/smoothapt-client-ca.pem;
    ssl_verify_client optional;
    ssl_verify_depth 1;

    location / {
        proxy_pass http://10.1.0.252:80;
        proxy_http_version 1.1;
        proxy_set_header Host              $host;
        proxy_set_header X-Real-IP         $remote_addr;
        proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        # Always set, so a client cannot supply its own.
        proxy_set_header X-Client-Verify   $ssl_client_verify;
        proxy_set_header X-Client-Serial   $ssl_client_serial;
        proxy_set_header X-Client-DN       $ssl_client_s_dn;
        proxy_read_timeout 60s;
    }
}
```
