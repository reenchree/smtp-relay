FROM ruby:3.4.11-alpine3.24@sha256:50133d02799e7da49a1e0bd16d865701622fd61d150a8cd3463edf0016504af5 AS build
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN apk add --no-cache build-base \
 && bundle config set without test \
 && bundle config set frozen true \
 && bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

FROM ruby:3.4.11-alpine3.24@sha256:50133d02799e7da49a1e0bd16d865701622fd61d150a8cd3463edf0016504af5
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY lib lib
COPY bin bin
USER 65534:65534
EXPOSE 2525 9090
ENTRYPOINT ["bundle", "exec", "ruby", "/app/bin/relay"]
