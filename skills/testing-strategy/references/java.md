# Java and Spring Boot

Required first step: before writing any test, read `~/.claude/skills/java-junit/SKILL.md`, plus any of its references the task needs. If you cannot read it, say so in your report. This file adds only Spring Boot and project-specific rules.

## First, detect

- Spring Boot version, module layout, shared test configs, custom security annotations and base test classes. Reuse them.
- Whether the project uses Testcontainers.
- Do not add JaCoCo, PIT, AssertJ or a JUnit upgrade unless the brief allows it.
- On JDK 21, keep any existing Surefire `argLine` for the Mockito agent. Report a missing setup instead of changing the build.

## Choose the smallest test

| Target | Tooling |
| --- | --- |
| Service or domain logic | Plain JUnit with Mockito, no Spring context |
| Controller: routing, validation, status codes, security | `@WebMvcTest` with `MockMvc` |
| Repository queries | `@DataJpaTest` |
| Serialization | `@JsonTest` |
| Full wiring of a critical flow | `@SpringBootTest`, sparingly |

## Spring

- Mock beans with `@MockitoBean` on Spring Boot 3.4 or later. Older versions use `@MockBean`.
- Each distinct set of mocked beans creates a new cached context, so share configurations. Avoid `@DirtiesContext` unless nothing else works.
- For secured endpoints, test 401 and 403 as well as success. Use `@WithMockUser` or the project's own annotation.
- A test-level `@Transactional` rolls back and can hide commit-time failures. It also does not cover other threads or a `RANDOM_PORT` server.
- Use Awaitility for async results, never `Thread.sleep`.
- Use Testcontainers if the project has it. H2 can behave differently from the production database.

## Multi-module Maven

`./mvnw test -pl modules/billing -am -Dtest=InvoiceServiceTest -Dsurefire.failIfNoSpecifiedTests=false`

Use `mvn` when the project has no wrapper.
