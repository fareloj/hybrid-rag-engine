package dev.rag.lexical;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import java.util.concurrent.Executors;
import org.apache.lucene.analysis.standard.StandardAnalyzer;
import org.apache.lucene.document.Document;
import org.apache.lucene.document.Field;
import org.apache.lucene.document.StoredField;
import org.apache.lucene.document.StringField;
import org.apache.lucene.document.TextField;
import org.apache.lucene.index.DirectoryReader;
import org.apache.lucene.index.IndexWriter;
import org.apache.lucene.index.IndexWriterConfig;
import org.apache.lucene.queryparser.classic.MultiFieldQueryParser;
import org.apache.lucene.search.IndexSearcher;
import org.apache.lucene.search.Query;
import org.apache.lucene.search.ScoreDoc;
import org.apache.lucene.search.TopDocs;
import org.apache.lucene.search.similarities.BM25Similarity;
import org.apache.lucene.store.ByteBuffersDirectory;
import org.apache.lucene.store.Directory;

public final class Main {
    private static final ObjectMapper JSON = new ObjectMapper();
    private static final StandardAnalyzer ANALYZER = new StandardAnalyzer();
    private static final ReentrantReadWriteLock LOCK = new ReentrantReadWriteLock();
    private static Directory directory = new ByteBuffersDirectory();
    private static int indexedCount = 0;

    private Main() {}

    public static void main(String[] args) throws IOException {
        int port = Integer.parseInt(System.getenv().getOrDefault("LEXICAL_INDEX_PORT", "8082"));
        HttpServer server = HttpServer.create(new InetSocketAddress("0.0.0.0", port), 0);
        server.createContext("/health", Main::health);
        server.createContext("/index", Main::index);
        server.createContext("/search", Main::search);
        server.createContext("/", Main::notFound);
        server.setExecutor(Executors.newFixedThreadPool(Math.max(4, Runtime.getRuntime().availableProcessors())));
        server.start();
        System.out.printf("lexical-index-java listening on %d%n", port);
    }

    private static void health(HttpExchange exchange) throws IOException {
        ObjectNode body = JSON.createObjectNode();
        body.put("status", "ok");
        body.put("service", "lexical-index-java");
        body.put("indexed", indexedCount);
        writeJson(exchange, 200, body);
    }

    private static void index(HttpExchange exchange) throws IOException {
        logRequest(exchange, "/index");
        if (!"POST".equals(exchange.getRequestMethod())) {
            writeError(exchange, 405, "method not allowed");
            return;
        }
        try {
            JsonNode body = JSON.readTree(exchange.getRequestBody());
            JsonNode chunks = body.get("chunks");
            if (chunks == null || !chunks.isArray()) {
                throw new IllegalArgumentException("chunks must be an array");
            }

            Directory nextDirectory = new ByteBuffersDirectory();
            IndexWriterConfig config = new IndexWriterConfig(ANALYZER);
            config.setSimilarity(new BM25Similarity());
            int count = 0;
            try (IndexWriter writer = new IndexWriter(nextDirectory, config)) {
                for (JsonNode chunk : chunks) {
                    String id = requiredText(chunk, "id");
                    String text = requiredText(chunk, "text");
                    if (text.isBlank()) {
                        throw new IllegalArgumentException("chunk text cannot be blank");
                    }
                    Document document = new Document();
                    document.add(new StringField("chunk_id", id, Field.Store.YES));
                    document.add(new TextField("text", text, Field.Store.NO));
                    document.add(new TextField("path", chunk.path("path").asText(""), Field.Store.YES));
                    document.add(new StringField("language", chunk.path("language").asText(""), Field.Store.YES));
                    document.add(new StoredField("start_line", chunk.path("start_line").asInt(0)));
                    document.add(new StoredField("end_line", chunk.path("end_line").asInt(0)));
                    writer.addDocument(document);
                    count++;
                }
            }

            LOCK.writeLock().lock();
            try {
                directory.close();
                directory = nextDirectory;
                indexedCount = count;
            } finally {
                LOCK.writeLock().unlock();
            }

            ObjectNode response = JSON.createObjectNode();
            response.put("status", "ok");
            response.put("indexed", count);
            writeJson(exchange, 200, response);
        } catch (Exception error) {
            writeError(exchange, 400, error.getMessage());
        }
    }

    private static void search(HttpExchange exchange) throws IOException {
        logRequest(exchange, "/search");
        if (!"POST".equals(exchange.getRequestMethod())) {
            writeError(exchange, 405, "method not allowed");
            return;
        }
        try {
            JsonNode body = JSON.readTree(exchange.getRequestBody());
            String queryText = requiredText(body, "query");
            int topK = Math.max(0, body.path("top_k").asInt(10));
            ObjectNode response = JSON.createObjectNode();
            ArrayNode results = response.putArray("results");
            if (queryText.isBlank() || topK == 0) {
                writeJson(exchange, 200, response);
                return;
            }

            LOCK.readLock().lock();
            try {
                if (indexedCount == 0) {
                    writeJson(exchange, 200, response);
                    return;
                }
                try (DirectoryReader reader = DirectoryReader.open(directory)) {
                    IndexSearcher searcher = new IndexSearcher(reader);
                    searcher.setSimilarity(new BM25Similarity());
                    Query query = parseQuery(queryText);
                    TopDocs topDocs = searcher.search(query, topK);
                    int rank = 1;
                    for (ScoreDoc scoreDoc : topDocs.scoreDocs) {
                        Document doc = searcher.storedFields().document(scoreDoc.doc);
                        ObjectNode item = results.addObject();
                        item.put("chunk_id", doc.get("chunk_id"));
                        item.put("score", scoreDoc.score);
                        item.put("rank", rank++);
                        item.put("source", "lexical-java-bm25");
                        item.put("path", doc.get("path"));
                        item.put("language", doc.get("language"));
                        item.put("start_line", doc.getField("start_line").numericValue().intValue());
                        item.put("end_line", doc.getField("end_line").numericValue().intValue());
                    }
                }
            } finally {
                LOCK.readLock().unlock();
            }
            writeJson(exchange, 200, response);
        } catch (Exception error) {
            writeError(exchange, 400, error.getMessage());
        }
    }

    private static Query parseQuery(String queryText) throws Exception {
        Map<String, Float> boosts = new HashMap<>();
        boosts.put("text", 1.0f);
        boosts.put("path", 2.0f);
        boosts.put("language", 0.5f);
        MultiFieldQueryParser parser = new MultiFieldQueryParser(new String[] {"text", "path", "language"}, ANALYZER, boosts);
        try {
            return parser.parse(queryText);
        } catch (Exception ignored) {
            return parser.parse(MultiFieldQueryParser.escape(queryText));
        }
    }

    private static String requiredText(JsonNode node, String field) {
        JsonNode value = node.get(field);
        if (value == null || value.asText().isEmpty()) {
            throw new IllegalArgumentException(field + " is required");
        }
        return value.asText();
    }

    private static void notFound(HttpExchange exchange) throws IOException {
        logRequest(exchange, exchange.getRequestURI().getPath());
        writeError(exchange, 404, "not found");
    }

    private static void logRequest(HttpExchange exchange, String path) {
        String requestId = exchange.getRequestHeaders().getFirst("X-Request-ID");
        if (requestId == null) {
            requestId = "";
        }
        System.out.printf(
            "{\"event\":\"lexical_request\",\"request_id\":\"%s\",\"method\":\"%s\",\"path\":\"%s\"}%n",
            requestId,
            exchange.getRequestMethod(),
            path
        );
    }

    private static void writeError(HttpExchange exchange, int statusCode, String message) throws IOException {
        ObjectNode body = JSON.createObjectNode();
        body.put("status", "error");
        body.put("error", message == null ? "unknown error" : message);
        writeJson(exchange, statusCode, body);
    }

    private static void writeJson(HttpExchange exchange, int statusCode, JsonNode body) throws IOException {
        byte[] bytes = JSON.writeValueAsBytes(body);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(statusCode, bytes.length);
        try (OutputStream output = exchange.getResponseBody()) {
            output.write(bytes);
        }
    }
}
