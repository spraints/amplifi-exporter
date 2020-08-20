FROM ruby:2.6.6

WORKDIR /app
COPY Gemfile      Gemfile
COPY Gemfile.lock Gemfile.lock
RUN bundle install

COPY main.rb      main.rb

ENTRYPOINT ["bundle", "exec", "ruby", "main.rb", "--address", "0.0.0.0"]
