#include <cstdlib>
#include <algorithm>
#include <cctype>
#include <chrono>
#include <cmath>
#include <filesystem>
#include <fstream>
#include <hnswlib/hnswlib.h>
#include <iostream>
#include <limits>
#include <memory>
#include <mutex>
#include <netinet/in.h>
#include <nlohmann/json.hpp>
#include <optional>
#include <shared_mutex>
#include <sstream>
#include <string>
#include <sys/socket.h>
#include <thread>
#include <unistd.h>
#include <vector>

using json = nlohmann::json;

namespace {

struct VectorEntry {
    std::string chunk_id;
    std::vector<float> values;
};

std::vector<VectorEntry> g_index;
struct HnswState {
    std::unique_ptr<hnswlib::InnerProductSpace> space;
    std::unique_ptr<hnswlib::HierarchicalNSW<float>> index;
    std::vector<std::string> ids;
    std::size_t dimensions = 0;
};

std::unique_ptr<HnswState> g_hnsw;
std::shared_mutex g_index_mutex;

std::string env_string(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return value == nullptr ? fallback : value;
}

std::size_t env_size(const char* name, std::size_t fallback, std::size_t minimum, std::size_t maximum) {
    const char* value = std::getenv(name);
    const auto parsed = value == nullptr ? fallback : static_cast<std::size_t>(std::stoul(value));
    if (parsed < minimum || parsed > maximum) {
        throw std::invalid_argument(std::string(name) + " must be between " + std::to_string(minimum) + " and " + std::to_string(maximum));
    }
    return parsed;
}

const std::string g_default_mode = env_string("DENSE_SEARCH_MODE", "hnsw");
const std::string g_storage_path = env_string("DENSE_INDEX_STORAGE_PATH", "/data");
const std::size_t g_hnsw_m = env_size("HNSW_M", 16, 2, 100);
const std::size_t g_hnsw_ef_construction = env_size("HNSW_EF_CONSTRUCTION", 200, 10, 10'000);
const std::size_t g_hnsw_ef_search = env_size("HNSW_EF_SEARCH", 100, 1, 10'000);

int read_port() {
    const char* value = std::getenv("DENSE_INDEX_PORT");
    if (value == nullptr) {
        return 8081;
    }
    return std::atoi(value);
}

void send_response(int client_fd, const std::string& status, const std::string& content_type, const std::string& body) {
    std::string response = "HTTP/1.1 " + status + "\r\n"
        + "Content-Type: " + content_type + "\r\n"
        + "Content-Length: " + std::to_string(body.size()) + "\r\n"
        + "Connection: close\r\n\r\n"
        + body;
    send(client_fd, response.c_str(), response.size(), 0);
}

std::string request_method(const std::string& request) {
    const auto first_space = request.find(' ');
    if (first_space == std::string::npos) {
        return "GET";
    }
    return request.substr(0, first_space);
}

std::string request_path(const std::string& request) {
    const auto first_space = request.find(' ');
    if (first_space == std::string::npos) {
        return "/";
    }
    const auto second_space = request.find(' ', first_space + 1);
    if (second_space == std::string::npos) {
        return "/";
    }
    return request.substr(first_space + 1, second_space - first_space - 1);
}

std::optional<std::size_t> content_length(const std::string& request) {
    const std::string header = "Content-Length:";
    const auto position = request.find(header);
    if (position == std::string::npos) {
        return std::nullopt;
    }
    const auto value_start = position + header.size();
    const auto line_end = request.find("\r\n", value_start);
    std::string value = request.substr(value_start, line_end - value_start);
    value.erase(std::remove_if(value.begin(), value.end(), ::isspace), value.end());
    return static_cast<std::size_t>(std::stoul(value));
}

std::string request_body(const std::string& request) {
    const auto body_start = request.find("\r\n\r\n");
    if (body_start == std::string::npos) {
        return "";
    }
    return request.substr(body_start + 4);
}

std::string request_header(const std::string& request, const std::string& header_name) {
    std::istringstream stream(request);
    std::string line;
    const std::string prefix = header_name + ":";
    while (std::getline(stream, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        if (line.rfind(prefix, 0) == 0) {
            std::string value = line.substr(prefix.size());
            value.erase(value.begin(), std::find_if(value.begin(), value.end(), [](unsigned char ch) {
                return !std::isspace(ch);
            }));
            return value;
        }
    }
    return "";
}

std::string read_request(int client_fd) {
    std::string request;
    char buffer[8192];
    while (true) {
        const ssize_t bytes_read = read(client_fd, buffer, sizeof(buffer));
        if (bytes_read <= 0) {
            break;
        }
        request.append(buffer, static_cast<std::size_t>(bytes_read));
        const auto header_end = request.find("\r\n\r\n");
        if (header_end != std::string::npos) {
            const auto length = content_length(request).value_or(0);
            const auto current_body_size = request.size() - header_end - 4;
            if (current_body_size >= length) {
                break;
            }
        }
    }
    return request;
}

double dot_product(const std::vector<float>& left, const std::vector<float>& right) {
    if (left.size() != right.size()) {
        return -std::numeric_limits<double>::infinity();
    }
    double score = 0.0;
    for (std::size_t index = 0; index < left.size(); ++index) {
        score += static_cast<double>(left[index]) * static_cast<double>(right[index]);
    }
    return score;
}

bool is_valid_vector(const std::vector<float>& values) {
    if (values.empty()) {
        return false;
    }
    return std::all_of(values.begin(), values.end(), [](float value) {
        return std::isfinite(value);
    });
}

std::filesystem::path index_file() {
    return std::filesystem::path(g_storage_path) / "hnsw.bin";
}

std::filesystem::path manifest_file() {
    return std::filesystem::path(g_storage_path) / "manifest.json";
}

std::unique_ptr<HnswState> build_hnsw(const std::vector<VectorEntry>& vectors) {
    if (vectors.empty()) {
        return nullptr;
    }
    auto state = std::make_unique<HnswState>();
    state->dimensions = vectors.front().values.size();
    state->space = std::make_unique<hnswlib::InnerProductSpace>(state->dimensions);
    state->index = std::make_unique<hnswlib::HierarchicalNSW<float>>(
        state->space.get(), vectors.size(), g_hnsw_m, g_hnsw_ef_construction
    );
    state->ids.reserve(vectors.size());
    for (std::size_t label = 0; label < vectors.size(); ++label) {
        state->index->addPoint(vectors[label].values.data(), label);
        state->ids.push_back(vectors[label].chunk_id);
    }
    state->index->setEf(g_hnsw_ef_search);
    return state;
}

void persist_hnsw(const HnswState* state) {
    std::filesystem::create_directories(g_storage_path);
    if (state == nullptr) {
        std::filesystem::remove(index_file());
        std::filesystem::remove(manifest_file());
        return;
    }

    const auto index_temp = index_file().string() + ".tmp";
    const auto manifest_temp = manifest_file().string() + ".tmp";
    state->index->saveIndex(index_temp);
    std::ofstream output(manifest_temp, std::ios::trunc);
    if (!output) {
        throw std::runtime_error("cannot write HNSW manifest");
    }
    output << json({
        {"dimensions", state->dimensions},
        {"ids", state->ids},
        {"m", g_hnsw_m},
        {"ef_construction", g_hnsw_ef_construction},
        {"ef_search", g_hnsw_ef_search}
    }).dump();
    output.close();
    std::filesystem::remove(index_file());
    std::filesystem::remove(manifest_file());
    std::filesystem::rename(index_temp, index_file());
    std::filesystem::rename(manifest_temp, manifest_file());
}

void load_persisted_hnsw() {
    if (!std::filesystem::exists(index_file()) || !std::filesystem::exists(manifest_file())) {
        return;
    }
    std::ifstream input(manifest_file());
    const json manifest = json::parse(input);
    auto state = std::make_unique<HnswState>();
    state->dimensions = manifest.at("dimensions").get<std::size_t>();
    state->ids = manifest.at("ids").get<std::vector<std::string>>();
    state->space = std::make_unique<hnswlib::InnerProductSpace>(state->dimensions);
    state->index = std::make_unique<hnswlib::HierarchicalNSW<float>>(state->space.get(), index_file().string());
    state->index->setEf(g_hnsw_ef_search);
    if (state->index->getCurrentElementCount() != state->ids.size()) {
        throw std::runtime_error("persisted HNSW manifest count mismatch");
    }

    std::vector<VectorEntry> restored;
    restored.reserve(state->ids.size());
    for (std::size_t label = 0; label < state->ids.size(); ++label) {
        restored.push_back({state->ids[label], state->index->getDataByLabel<float>(label)});
    }
    g_index = std::move(restored);
    g_hnsw = std::move(state);
    std::cout << "{\"event\":\"dense_index_loaded\",\"indexed\":" << g_index.size() << "}" << std::endl;
}

json handle_index(const json& payload) {
    std::vector<VectorEntry> next_index;
    for (const auto& item : payload.at("vectors")) {
        VectorEntry entry;
        entry.chunk_id = item.at("chunk_id").get<std::string>();
        entry.values = item.at("values").get<std::vector<float>>();
        if (entry.chunk_id.empty() || !is_valid_vector(entry.values)) {
            throw std::invalid_argument("invalid vector entry");
        }
        if (!next_index.empty() && next_index.front().values.size() != entry.values.size()) {
            throw std::invalid_argument("all vectors must have the same dimension");
        }
        next_index.push_back(std::move(entry));
    }

    auto next_hnsw = build_hnsw(next_index);
    persist_hnsw(next_hnsw.get());
    const auto indexed_count = next_index.size();
    const auto dimensions = next_index.empty() ? 0 : next_index.front().values.size();
    {
        std::unique_lock lock(g_index_mutex);
        g_index = std::move(next_index);
        g_hnsw = std::move(next_hnsw);
    }

    return {
        {"status", "ok"},
        {"indexed", indexed_count},
        {"dimensions", dimensions},
        {"modes", {"linear", "hnsw"}},
        {"default_mode", g_default_mode}
    };
}

json handle_search(const json& payload) {
    const auto started = std::chrono::steady_clock::now();
    const auto elapsed_ms = [&started]() {
        return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - started).count();
    };
    const auto query = payload.at("embedding").get<std::vector<float>>();
    const auto top_k = std::clamp(payload.value("top_k", 10), 0, 1000);
    const auto mode = payload.value("mode", g_default_mode);
    if (!is_valid_vector(query)) {
        throw std::invalid_argument("invalid query vector");
    }
    if (mode != "linear" && mode != "hnsw") {
        throw std::invalid_argument("mode must be linear or hnsw");
    }

    std::shared_lock lock(g_index_mutex);
    if (!g_index.empty() && g_index.front().values.size() != query.size()) {
        throw std::invalid_argument("query vector dimension does not match index dimension");
    }
    const auto limit = std::min<std::size_t>(static_cast<std::size_t>(top_k), g_index.size());
    json results = json::array();

    if (mode == "hnsw" && g_hnsw != nullptr && limit > 0) {
        auto neighbors = g_hnsw->index->searchKnn(query.data(), limit);
        std::vector<std::pair<float, hnswlib::labeltype>> ordered;
        ordered.reserve(neighbors.size());
        while (!neighbors.empty()) {
            ordered.push_back(neighbors.top());
            neighbors.pop();
        }
        std::reverse(ordered.begin(), ordered.end());
        for (std::size_t rank = 0; rank < ordered.size(); ++rank) {
            const auto [distance, label] = ordered[rank];
            results.push_back({
                {"chunk_id", g_hnsw->ids.at(label)},
                {"score", 1.0 - static_cast<double>(distance)},
                {"rank", rank + 1},
                {"source", "dense-cpp-hnsw"}
            });
        }
        return {{"mode", mode}, {"latency_ms", elapsed_ms()}, {"results", results}};
    }

    std::vector<std::pair<std::string, double>> scored;
    scored.reserve(g_index.size());
    for (const auto& entry : g_index) {
        scored.emplace_back(entry.chunk_id, dot_product(query, entry.values));
    }

    lock.unlock();
    std::sort(scored.begin(), scored.end(), [](const auto& left, const auto& right) {
        if (left.second == right.second) {
            return left.first < right.first;
        }
        return left.second > right.second;
    });

    for (std::size_t index = 0; index < limit; ++index) {
        results.push_back({
            {"chunk_id", scored[index].first},
            {"score", scored[index].second},
            {"rank", index + 1},
            {"source", "dense-cpp-linear"}
        });
    }
    return {{"mode", "linear"}, {"latency_ms", elapsed_ms()}, {"results", results}};
}

}  // namespace

int main() {
    const int port = read_port();
    const int server_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (server_fd < 0) {
        std::cerr << "failed to create socket\n";
        return 1;
    }

    int opt = 1;
    setsockopt(server_fd, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);

    if (bind(server_fd, reinterpret_cast<sockaddr*>(&address), sizeof(address)) < 0) {
        std::cerr << "failed to bind port " << port << "\n";
        close(server_fd);
        return 1;
    }

    if (listen(server_fd, 64) < 0) {
        std::cerr << "failed to listen\n";
        close(server_fd);
        return 1;
    }

    try {
        load_persisted_hnsw();
    } catch (const std::exception& error) {
        std::cerr << "{\"event\":\"dense_index_load_failed\",\"error\":\"" << error.what() << "\"}" << std::endl;
        g_index.clear();
        g_hnsw.reset();
    }

    std::cout << "dense-index-cpp listening on " << port << "\n";

    while (true) {
        int client_fd = accept(server_fd, nullptr, nullptr);
        if (client_fd < 0) {
            continue;
        }

        std::thread([client_fd]() {
            const std::string request = read_request(client_fd);
            if (request.empty()) {
                close(client_fd);
                return;
            }

            const std::string method = request_method(request);
            const std::string path = request_path(request);
            const std::string request_id = request_header(request, "X-Request-ID");
            std::cout << "{\"event\":\"dense_request\",\"request_id\":\"" << request_id
                      << "\",\"method\":\"" << method << "\",\"path\":\"" << path << "\"}" << std::endl;
            try {
                if (method == "GET" && path == "/health") {
                    json body;
                    {
                        std::shared_lock lock(g_index_mutex);
                        body = {
                            {"status", "ok"},
                            {"service", "dense-index-cpp"},
                            {"indexed", g_index.size()},
                            {"dimensions", g_index.empty() ? 0 : g_index.front().values.size()},
                            {"default_mode", g_default_mode},
                            {"modes", {"linear", "hnsw"}},
                            {"hnsw", {
                                {"loaded", g_hnsw != nullptr},
                                {"m", g_hnsw_m},
                                {"ef_construction", g_hnsw_ef_construction},
                                {"ef_search", g_hnsw_ef_search}
                            }}
                        };
                    }
                    send_response(client_fd, "200 OK", "application/json", body.dump());
                } else if (method == "POST" && path == "/index") {
                    send_response(client_fd, "200 OK", "application/json", handle_index(json::parse(request_body(request))).dump());
                } else if (method == "POST" && path == "/search") {
                    send_response(client_fd, "200 OK", "application/json", handle_search(json::parse(request_body(request))).dump());
                } else {
                    send_response(client_fd, "404 Not Found", "application/json", R"({"status":"not_found"})");
                }
            } catch (const std::exception& error) {
                json body = {{"status", "error"}, {"error", error.what()}};
                send_response(client_fd, "400 Bad Request", "application/json", body.dump());
            }

            close(client_fd);
        }).detach();
    }
}
