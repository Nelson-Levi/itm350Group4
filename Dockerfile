FROM ghost:5-alpine

ENV NODE_ENV=production
# To make it simpler
ENV database__client=sqlite3 
ENV database__connection__filename=/var/lib/ghost/content/data/ghost.db

# Ghost runs on 2368 by default (documentation)
EXPOSE 2368

# Official image already has the CMD set, so we don't need to set it again.