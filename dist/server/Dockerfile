FROM node:18-alpine

# Install build dependencies for better-sqlite3
RUN apk add --no-cache python3 make g++ sqlite

WORKDIR /app

# Copy package files from dist/server
COPY dist/server/package*.json ./

# Install dependencies (including native modules)
RUN npm ci --only=production

# Copy app source from dist/server
COPY dist/server/ .

# Expose port
EXPOSE 3000

# Start the server
CMD ["npm", "start"]
