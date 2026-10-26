FROM ruby:3.4.11-alpine3.24@sha256:aa205a3ebbf558c304cd135c197af8e80cf6c26193ec4b5862763562f1c38426 AS build
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN apk add --no-cache build-base \
 && bundle config set without test \
 && bundle config set frozen true \
 && bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

FROM ruby:3.4.11-alpine3.24@sha256:aa205a3ebbf558c304cd135c197af8e80cf6c26193ec4b5862763562f1c38426
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY lib lib
COPY bin bin
USER 65534:65534
EXPOSE 2525 9090
ENTRYPOINT ["bundle", "exec", "ruby", "/app/bin/relay"]
