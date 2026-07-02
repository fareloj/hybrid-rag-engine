FROM maven:3.9-eclipse-temurin-21 AS build

WORKDIR /src
COPY pom.xml .
COPY src ./src
RUN mvn -q -DskipTests package dependency:copy-dependencies

FROM eclipse-temurin:21-jre

RUN apt-get update \
    && apt-get install -y --no-install-recommends wget \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /src/target/classes ./classes
COPY --from=build /src/target/dependency ./dependency

EXPOSE 8082

CMD ["java", "-cp", "classes:dependency/*", "dev.rag.lexical.Main"]
