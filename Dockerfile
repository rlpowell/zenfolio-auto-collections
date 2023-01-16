FROM docker.io/library/ruby:2.7

# Needed for image/video handling
RUN apt-get update
RUN apt-get install -y imagemagick ffmpeg findutils vim zsh moreutils make git wget curl

RUN gem install nokogiri
RUN gem install parallel

RUN mkdir /src /pics
WORKDIR /src
