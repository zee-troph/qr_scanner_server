# Start from the Dart SDK image
FROM dart:stable AS build

# Resolve app dependencies.
WORKDIR /app
COPY pubspec.* ./
COPY .dockerignore .dockerignore 
RUN dart pub get

# Copy all source code
COPY . .

# Compile server (optional depending on your style)
RUN dart compile exe bin/qr_server.dart -o bin/qr_server

# Build minimal serving image from AOT-compiled binary and required files
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/bin/qr_server /app/bin/qr_server
COPY --from=build /app/.dart_tool/package_config.json /app/.dart_tool/package_config.json
CMD ["/app/bin/qr_server"]