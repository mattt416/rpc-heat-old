# let Heat know we are done
curl -i -H 'Content-Type:' -X PUT --data-binary '{"status":"SUCCESS"}' '%%SIGNAL%%'
