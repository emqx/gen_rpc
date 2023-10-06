FROM erlang:latest

ENV DEBIAN_FRONTEND=noninteractive
ENV HOME=/root
ENV TERM=xterm-256color

ADD . /gen_rpc
WORKDIR "/gen_rpc"
RUN make
