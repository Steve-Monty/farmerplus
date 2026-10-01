FROM quay.io/keycloak/keycloak:26.7.4 AS distribution
FROM eclipse-temurin:21-jdk AS apple-builder
COPY --from=distribution /opt/keycloak /opt/keycloak
COPY apple/src /src
COPY apple/resources /resources
COPY verification/src /verification-src
COPY verification/resources /verification-resources
COPY verification/test /verification-test
RUN mkdir -p /classes && \
    javac --release 21 -cp '/opt/keycloak/lib/lib/main/*' -d /classes $(find /src /verification-src -name '*.java') && \
    cp -R /resources/META-INF /classes/ && \
    cp -R /verification-resources/META-INF /classes/ && \
    javac --release 21 -cp /classes -d /test-classes $(find /verification-test -name '*.java') && \
    java -cp /classes:/test-classes earth.farmerplus.keycloak.VerificationCodeTest && \
    jar --create --file /farmerplus-apple.jar -C /classes .

FROM quay.io/keycloak/keycloak:26.7.4
COPY --chown=1000:0 themes /opt/keycloak/themes
COPY --from=apple-builder --chown=1000:0 /farmerplus-apple.jar /opt/keycloak/providers/farmerplus-apple.jar
RUN /opt/keycloak/bin/kc.sh build --db=postgres --health-enabled=true --metrics-enabled=true
ENTRYPOINT ["/opt/keycloak/bin/kc.sh"]
