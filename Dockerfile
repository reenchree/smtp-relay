FROM ruby:3.4.13-alpine3.24@sha256:9010b7942739e483ab8e359eae1190ea10af21cf7476daa41ece6f896dc8e02a AS build
WORKDIR /app
COPY Gemfile Gemfile.lock ./
RUN apk add --no-cache build-base \
 && bundle config set without test \
 && bundle config set frozen true \
 && bundle install --jobs 4 \
 && rm -rf /usr/local/bundle/cache

FROM ruby:3.4.13-alpine3.24@sha256:9010b7942739e483ab8e359eae1190ea10af21cf7476daa41ece6f896dc8e02a
WORKDIR /app
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY Gemfile Gemfile.lock ./
COPY lib lib
COPY bin bin
USER 65534:65534
EXPOSE 2525 9090
ENTRYPOINT ["bundle", "exec", "ruby", "/app/bin/relay"]
