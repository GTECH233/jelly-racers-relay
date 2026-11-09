# Jelly Racers online relay server.
# Build & run locally:   docker build -t jelly-relay .   then   docker run -p 24600:24600 jelly-relay
# Hosting services (Render, Fly.io, Railway...) can build this folder directly.
FROM debian:bookworm-slim

RUN apt-get update \
	&& apt-get install -y --no-install-recommends wget unzip ca-certificates libfontconfig1 \
	&& rm -rf /var/lib/apt/lists/*

# The official Godot 4.6.3 build (same engine version as the game)
RUN wget -q https://github.com/godotengine/godot/releases/download/4.6.3-stable/Godot_v4.6.3-stable_linux.x86_64.zip -O /tmp/godot.zip \
	&& unzip /tmp/godot.zip -d /opt \
	&& mv /opt/Godot_v4.6.3-stable_linux.x86_64 /usr/local/bin/godot \
	&& chmod +x /usr/local/bin/godot \
	&& rm /tmp/godot.zip

WORKDIR /app
COPY relay.gd project.godot ./

# Most hosts tell the app which port to use through $PORT; 24600 otherwise.
ENV PORT=24600
EXPOSE 24600
CMD ["godot", "--headless", "--path", "/app", "-s", "relay.gd"]
