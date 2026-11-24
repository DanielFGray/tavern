#!/bin/sh
# Starts SeaweedFS with an S3 API that accepts only Tavern's key pair. The store publishes no
# port: the app reads and writes every upload itself and serves it through its /uploads route.
set -eu

cat > /tmp/s3.json <<EOF
{
  "identities": [
    {
      "name": "tavern",
      "credentials": [{ "accessKey": "$S3_ACCESS_KEY_ID", "secretKey": "$S3_SECRET_ACCESS_KEY" }],
      "actions": ["Admin", "Read", "Write", "List", "Tagging"]
    }
  ]
}
EOF

exec weed server -dir=/data -s3 -s3.config=/tmp/s3.json
