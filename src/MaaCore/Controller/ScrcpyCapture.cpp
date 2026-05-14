#include "ScrcpyCapture.h"

#include "Controller/Platform/PlatformIO.h"
#include "MaaUtils/NoWarningCV.hpp"
#include "Utils/Logger.hpp"
#include "Utils/Platform.hpp"
#include "Utils/StringMisc.hpp"

#include <array>
#include <chrono>
#include <cstdint>
#include <limits>
#include <regex>
#include <tuple>
#include <vector>

#ifdef _WIN32
#include "MaaUtils/SafeWindows.hpp"
#else
#include <dlfcn.h>
#endif

using boost::asio::ip::tcp;

namespace
{
constexpr int AV_CODEC_ID_H264 = 27;
constexpr int AV_PIX_FMT_YUV420P = 0;
constexpr int AV_PIX_FMT_RGB24 = 2;
constexpr int AV_PIX_FMT_BGR24 = 3;
constexpr int AV_PIX_FMT_NV12 = 23;
constexpr int AV_PIX_FMT_NV21 = 24;
constexpr int64_t AV_NOPTS_VALUE = std::numeric_limits<int64_t>::min();

struct AVCodec;
struct AVCodecContext;
struct AVCodecParserContext;

struct AVPacket
{
    void* buf;
    int64_t pts;
    int64_t dts;
    uint8_t* data;
    int size;
};

struct AVFrame
{
    uint8_t* data[8];
    int linesize[8];
    uint8_t** extended_data;
    int width;
    int height;
    int nb_samples;
    int format;
};

template <typename Func>
Func load_func(void* module, const char* name)
{
#ifdef _WIN32
    auto proc = GetProcAddress(static_cast<HMODULE>(module), name);
#else
    auto proc = dlsym(module, name);
#endif
    if (!proc) {
        LogError << "Failed to load FFmpeg symbol" << name;
        return nullptr;
    }
    return reinterpret_cast<Func>(proc);
}

std::optional<std::filesystem::path> find_first_file(
    const std::filesystem::path& dir,
    std::string_view prefix,
    std::string_view extension)
{
    if (!std::filesystem::exists(dir)) {
        return std::nullopt;
    }

    for (const auto& entry : std::filesystem::directory_iterator(dir)) {
        if (!entry.is_regular_file()) {
            continue;
        }
        const auto filename = entry.path().filename().string();
        if (filename.starts_with(prefix) && entry.path().extension().string() == extension) {
            return entry.path();
        }
    }
    return std::nullopt;
}

std::vector<std::filesystem::path> runtime_search_dirs(const std::filesystem::path& runtime_dir)
{
    return {
        runtime_dir,
        runtime_dir / "common",
        runtime_dir / "win-x64",
    };
}

std::optional<std::filesystem::path> find_first_runtime_file(
    const std::filesystem::path& runtime_dir,
    std::string_view prefix,
    std::string_view extension)
{
    for (const auto& dir : runtime_search_dirs(runtime_dir)) {
        if (auto path = find_first_file(dir, prefix, extension)) {
            return path;
        }
    }
    return std::nullopt;
}

std::optional<std::filesystem::path> find_ffmpeg_lib(
    const std::filesystem::path& runtime_dir,
    std::string_view name)
{
#ifdef _WIN32
    return find_first_runtime_file(runtime_dir, std::string(name) + "-", ".dll");
#else
    const std::string prefix = "lib" + std::string(name);
    constexpr std::string_view so_marker =
#ifdef __APPLE__
        ".dylib";
#else
        ".so";
#endif
    for (const auto& dir : runtime_search_dirs(runtime_dir)) {
        if (!std::filesystem::exists(dir)) {
            continue;
        }
        for (const auto& entry : std::filesystem::directory_iterator(dir)) {
            if (!entry.is_regular_file()) {
                continue;
            }
            const auto fname = entry.path().filename().string();
            if (fname.starts_with(prefix) && fname.find(so_marker) != std::string::npos) {
                return entry.path();
            }
        }
    }
    return std::nullopt;
#endif
}

std::optional<std::filesystem::path> find_runtime_server(const std::filesystem::path& runtime_dir)
{
    for (const auto& dir : runtime_search_dirs(runtime_dir)) {
        auto path = dir / "scrcpy-server";
        if (std::filesystem::exists(path)) {
            return path;
        }
    }
    return std::nullopt;
}

std::string parse_version_from_path(const std::filesystem::path& path)
{
    const auto filename = path.filename().string();
    std::smatch match;
    static const std::regex VersionPattern(R"((?:^|[-_])v?(\d+\.\d+\.\d+)(?:$|[-_]))", std::regex::icase);
    return std::regex_search(filename, match, VersionPattern) ? match[1].str() : std::string();
}

} // namespace

class asst::ScrcpyCapture::FFmpegDecoder
{
public:
    ~FFmpegDecoder() { close(); }

    bool open(const std::filesystem::path& runtime_dir)
    {
        close();

        auto avutil_path = find_ffmpeg_lib(runtime_dir, "avutil");
        auto avcodec_path = find_ffmpeg_lib(runtime_dir, "avcodec");
        if (!avutil_path || !avcodec_path) {
            LogError << "FFmpeg runtime is incomplete" << VAR(runtime_dir);
            return false;
        }

#ifdef _WIN32
        avutil_  = LoadLibraryExW(avutil_path->c_str(),  nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        avcodec_ = LoadLibraryExW(avcodec_path->c_str(), nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!avutil_ || !avcodec_) {
            LogError << "Failed to load FFmpeg libraries" << VAR(runtime_dir) << VAR(GetLastError());
            close();
            return false;
        }
#else
        avutil_  = dlopen(avutil_path->string().c_str(),  RTLD_NOW | RTLD_LOCAL);
        avcodec_ = dlopen(avcodec_path->string().c_str(), RTLD_NOW | RTLD_LOCAL);
        if (!avutil_ || !avcodec_) {
            LogError << "Failed to load FFmpeg libraries" << VAR(runtime_dir) << VAR(dlerror());
            close();
            return false;
        }
#endif

        avcodec_find_decoder_ = load_func<decltype(avcodec_find_decoder_)>(avcodec_, "avcodec_find_decoder");
        avcodec_alloc_context3_ = load_func<decltype(avcodec_alloc_context3_)>(avcodec_, "avcodec_alloc_context3");
        avcodec_open2_ = load_func<decltype(avcodec_open2_)>(avcodec_, "avcodec_open2");
        avcodec_free_context_ = load_func<decltype(avcodec_free_context_)>(avcodec_, "avcodec_free_context");
        av_parser_init_ = load_func<decltype(av_parser_init_)>(avcodec_, "av_parser_init");
        av_parser_parse2_ = load_func<decltype(av_parser_parse2_)>(avcodec_, "av_parser_parse2");
        av_parser_close_ = load_func<decltype(av_parser_close_)>(avcodec_, "av_parser_close");
        av_packet_alloc_ = load_func<decltype(av_packet_alloc_)>(avcodec_, "av_packet_alloc");
        av_packet_free_ = load_func<decltype(av_packet_free_)>(avcodec_, "av_packet_free");
        av_packet_unref_ = load_func<decltype(av_packet_unref_)>(avcodec_, "av_packet_unref");
        avcodec_send_packet_ = load_func<decltype(avcodec_send_packet_)>(avcodec_, "avcodec_send_packet");
        avcodec_receive_frame_ = load_func<decltype(avcodec_receive_frame_)>(avcodec_, "avcodec_receive_frame");
        av_frame_alloc_ = load_func<decltype(av_frame_alloc_)>(avutil_, "av_frame_alloc");
        av_frame_free_ = load_func<decltype(av_frame_free_)>(avutil_, "av_frame_free");
        av_frame_unref_ = load_func<decltype(av_frame_unref_)>(avutil_, "av_frame_unref");

        if (!avcodec_find_decoder_ || !avcodec_alloc_context3_ || !avcodec_open2_ || !avcodec_free_context_ ||
            !av_parser_init_ || !av_parser_parse2_ || !av_parser_close_ || !av_packet_alloc_ || !av_packet_free_ ||
            !av_packet_unref_ || !avcodec_send_packet_ || !avcodec_receive_frame_ || !av_frame_alloc_ ||
            !av_frame_free_ || !av_frame_unref_) {
            close();
            return false;
        }

        const AVCodec* codec = avcodec_find_decoder_(AV_CODEC_ID_H264);
        if (!codec) {
            LogError << "H.264 decoder is not available in FFmpeg";
            close();
            return false;
        }

        codec_ctx_ = avcodec_alloc_context3_(codec);
        parser_ctx_ = av_parser_init_(AV_CODEC_ID_H264);
        packet_ = av_packet_alloc_();
        frame_ = av_frame_alloc_();
        if (!codec_ctx_ || !parser_ctx_ || !packet_ || !frame_) {
            LogError << "Failed to allocate FFmpeg decoder objects" << VAR(codec_ctx_) << VAR(parser_ctx_)
                     << VAR(packet_) << VAR(frame_);
            close();
            return false;
        }
        if (avcodec_open2_(codec_ctx_, codec, nullptr) < 0) {
            LogError << "Failed to open H.264 decoder";
            close();
            return false;
        }
        return true;
    }

    bool decode(std::string_view data, cv::Mat& latest_frame)
    {
        if (!codec_ctx_ || !packet_ || !frame_) {
            return false;
        }

        auto* input = reinterpret_cast<const uint8_t*>(data.data());
        int input_size = static_cast<int>(data.size());
        bool got_frame = false;

        while (input_size > 0) {
            uint8_t* parsed_data = nullptr;
            int parsed_size = 0;
            int used = av_parser_parse2_(
                parser_ctx_,
                codec_ctx_,
                &parsed_data,
                &parsed_size,
                input,
                input_size,
                AV_NOPTS_VALUE,
                AV_NOPTS_VALUE,
                0);
            if (used < 0) {
                LogError << "Failed to parse H.264 stream";
                return got_frame;
            }

            input += used;
            input_size -= used;

            if (parsed_size <= 0) {
                continue;
            }

            packet_->data = parsed_data;
            packet_->size = parsed_size;
            if (avcodec_send_packet_(codec_ctx_, packet_) < 0) {
                av_packet_unref_(packet_);
                continue;
            }
            av_packet_unref_(packet_);

            while (avcodec_receive_frame_(codec_ctx_, frame_) == 0) {
                cv::Mat converted;
                if (convert_frame(converted)) {
                    latest_frame = std::move(converted);
                    got_frame = true;
                }
                av_frame_unref_(frame_);
            }
        }

        return got_frame;
    }

    bool convert_frame(cv::Mat& dst)
    {
        if (!frame_ || frame_->width <= 0 || frame_->height <= 0) {
            return false;
        }
        if (!convert_frame_by_opencv(dst)) {
            LogError << "Unsupported FFmpeg pixel format" << VAR(frame_->format);
            return false;
        }
        return true;
    }

    // BT.709 limited-range YCbCr -> BGR conversion (integer fixed-point, scaled by 1024).
    // H.264 uses limited range (studio swing): Y∈[16,235], Cb/Cr∈[16,240].
    // Coefficients (ITU-T BT.709 limited→full range):
    //   R = 1.164*(Y-16) + 1.793*(Cr-128)
    //   G = 1.164*(Y-16) - 0.213*(Cb-128) - 0.533*(Cr-128)
    //   B = 1.164*(Y-16) + 2.112*(Cb-128)
    // BT.601 shifts hue ~3 H-units, degrading HSV-based color recognition tasks.
    static void yuv_to_bgr_bt709(
        cv::Mat& dst,
        int width,
        int height,
        const uint8_t* y_data,
        int y_stride,
        const uint8_t* cb_data,
        int cb_stride,
        int cb_step, // 1 for planar, 2 for interleaved NV12/NV21
        const uint8_t* cr_data,
        int cr_stride,
        int cr_step)
    {
        dst.create(height, width, CV_8UC3);
        for (int r = 0; r < height; ++r) {
            const uint8_t* y_row  = y_data  + r          * y_stride;
            const uint8_t* cb_row = cb_data + (r >> 1)   * cb_stride;
            const uint8_t* cr_row = cr_data + (r >> 1)   * cr_stride;
            uint8_t* out = dst.ptr(r);
            for (int c = 0; c < width; ++c) {
                const int Y  = y_row[c] - 16;
                const int Cb = cb_row[(c >> 1) * cb_step] - 128;
                const int Cr = cr_row[(c >> 1) * cr_step] - 128;
                const int R = (1192 * Y + 1836 * Cr + 512) >> 10;
                const int G = (1192 * Y - 218 * Cb - 546 * Cr + 512) >> 10;
                const int B = (1192 * Y + 2163 * Cb + 512) >> 10;
                out[c * 3 + 0] = static_cast<uint8_t>(std::clamp(B, 0, 255));
                out[c * 3 + 1] = static_cast<uint8_t>(std::clamp(G, 0, 255));
                out[c * 3 + 2] = static_cast<uint8_t>(std::clamp(R, 0, 255));
            }
        }
    }

    bool convert_frame_by_opencv(cv::Mat& dst) const
    {
        const int width = frame_->width;
        const int height = frame_->height;
        if (frame_->format == AV_PIX_FMT_BGR24) {
            cv::Mat bgr(height, width, CV_8UC3, frame_->data[0], frame_->linesize[0]);
            dst = bgr.clone();
            return true;
        }
        if (frame_->format == AV_PIX_FMT_RGB24) {
            cv::Mat rgb(height, width, CV_8UC3, frame_->data[0], frame_->linesize[0]);
            cv::cvtColor(rgb, dst, cv::COLOR_RGB2BGR);
            return true;
        }
        if (frame_->format == AV_PIX_FMT_YUV420P && width % 2 == 0 && height % 2 == 0) {
            yuv_to_bgr_bt709(
                dst, width, height,
                frame_->data[0], frame_->linesize[0],
                frame_->data[1], frame_->linesize[1], 1,
                frame_->data[2], frame_->linesize[2], 1);
            return true;
        }
        if ((frame_->format == AV_PIX_FMT_NV12 || frame_->format == AV_PIX_FMT_NV21) && width % 2 == 0 &&
            height % 2 == 0) {
            // NV12: Cb at data[1][0,2,4,...], Cr at data[1][1,3,5,...]
            // NV21: Cr at data[1][0,2,4,...], Cb at data[1][1,3,5,...] — swap cb/cr pointers
            const uint8_t* cb = frame_->data[1] + (frame_->format == AV_PIX_FMT_NV21 ? 1 : 0);
            const uint8_t* cr = frame_->data[1] + (frame_->format == AV_PIX_FMT_NV21 ? 0 : 1);
            yuv_to_bgr_bt709(
                dst, width, height,
                frame_->data[0], frame_->linesize[0],
                cb, frame_->linesize[1], 2,
                cr, frame_->linesize[1], 2);
            return true;
        }
        return false;
    }

    void close()
    {
        if (frame_ && av_frame_free_) {
            av_frame_free_(&frame_);
        }
        if (packet_ && av_packet_free_) {
            av_packet_free_(&packet_);
        }
        if (parser_ctx_ && av_parser_close_) {
            av_parser_close_(parser_ctx_);
        }
        parser_ctx_ = nullptr;
        if (codec_ctx_ && avcodec_free_context_) {
            avcodec_free_context_(&codec_ctx_);
        }

#ifdef _WIN32
        if (avcodec_) { FreeLibrary(static_cast<HMODULE>(avcodec_)); avcodec_ = nullptr; }
        if (avutil_)  { FreeLibrary(static_cast<HMODULE>(avutil_));  avutil_  = nullptr; }
#else
        if (avcodec_) { dlclose(avcodec_); avcodec_ = nullptr; }
        if (avutil_)  { dlclose(avutil_);  avutil_  = nullptr; }
#endif
    }

private:
    void* avcodec_ = nullptr;
    void* avutil_ = nullptr;

    const AVCodec* (*avcodec_find_decoder_)(int) = nullptr;
    AVCodecContext* (*avcodec_alloc_context3_)(const AVCodec*) = nullptr;
    int (*avcodec_open2_)(AVCodecContext*, const AVCodec*, void*) = nullptr;
    void (*avcodec_free_context_)(AVCodecContext**) = nullptr;
    AVCodecParserContext* (*av_parser_init_)(int) = nullptr;
    int (*av_parser_parse2_)(
        AVCodecParserContext*,
        AVCodecContext*,
        uint8_t**,
        int*,
        const uint8_t*,
        int,
        int64_t,
        int64_t,
        int64_t) = nullptr;
    void (*av_parser_close_)(AVCodecParserContext*) = nullptr;
    AVPacket* (*av_packet_alloc_)() = nullptr;
    void (*av_packet_free_)(AVPacket**) = nullptr;
    void (*av_packet_unref_)(AVPacket*) = nullptr;
    int (*avcodec_send_packet_)(AVCodecContext*, const AVPacket*) = nullptr;
    int (*avcodec_receive_frame_)(AVCodecContext*, AVFrame*) = nullptr;
    AVFrame* (*av_frame_alloc_)() = nullptr;
    void (*av_frame_free_)(AVFrame**) = nullptr;
    void (*av_frame_unref_)(AVFrame*) = nullptr;

    AVCodecContext* codec_ctx_ = nullptr;
    AVCodecParserContext* parser_ctx_ = nullptr;
    AVPacket* packet_ = nullptr;
    AVFrame* frame_ = nullptr;
};

asst::ScrcpyCapture::ScrcpyCapture() : socket_(io_context_) {}

asst::ScrcpyCapture::~ScrcpyCapture()
{
    uninit();
}

bool asst::ScrcpyCapture::init(
    const AdbCfg& adb_cfg,
    const std::string& adb_path,
    const std::string& address,
    CommandRunner command_runner,
    ShellStarter shell_starter)
{
    uninit();

    adb_cfg_ = adb_cfg;
    adb_path_ = adb_path;
    address_ = address;
    command_runner_ = std::move(command_runner);
    shell_starter_ = std::move(shell_starter);
    server_version_ = adb_cfg.extras.get("version", "");
    if (server_version_.empty() && !adb_cfg.extras.get("path", "").empty()) {
        server_version_ = parse_version_from_path(utils::path(adb_cfg.extras.get("path", "")));
    }
    if (server_version_.empty()) {
        server_version_ = adb_cfg.scrcpy_server_version;
    }
    if (server_version_.empty()) {
        LogError << "ScrcpyCapture: server version not configured";
        return false;
    }

    inited_ = init_runtime() && setup_adb_tunnel() && start_server() && start_reader();
    LogInfo << "Init ScrcpyCapture" << VAR(inited_);
    if (!inited_) {
        uninit();
    }
    return inited_;
}

bool asst::ScrcpyCapture::reload()
{
    if (!command_runner_) {
        return false;
    }
    uninit();
    inited_ = init_runtime() && setup_adb_tunnel() && start_server() && start_reader();
    LogInfo << "Reload ScrcpyCapture" << VAR(inited_);
    if (!inited_) {
        uninit();
    }
    return inited_;
}

void asst::ScrcpyCapture::uninit()
{
    inited_ = false;
    stop_requested_ = true;
    close_socket();

    if (reader_thread_.joinable()) {
        reader_thread_.join();
    }
    reader_running_ = false;

    server_handler_.reset();

    if (command_runner_ && local_port_ != 0) {
        command_runner_(adb_prefix() + " forward --remove tcp:" + std::to_string(local_port_), 5000, false);
    }

    local_port_ = 0;
    decoder_.reset();
    {
        std::scoped_lock lock(frame_mutex_);
        front_frame_ = cv::Mat();
        back_frame_ = cv::Mat();
        frame_consumed_ = true;
    }
    frame_cv_.notify_all();
    stop_requested_ = false;
}

std::optional<cv::Mat> asst::ScrcpyCapture::screencap()
{
    std::unique_lock lock(frame_mutex_);
    frame_cv_.wait_for(lock, std::chrono::seconds(5),
                       [this] { return !frame_consumed_ || stop_requested_ || !reader_running_; });
    if (stop_requested_ || (!reader_running_ && frame_consumed_)) {
        return std::nullopt;
    }
    if (front_frame_.empty()) {
        LogWarn << "ScrcpyCapture: no frame available";
        return std::nullopt;
    }
    cv::Mat result = front_frame_.clone();
    frame_consumed_ = true;
    return result;
}

bool asst::ScrcpyCapture::init_runtime()
{
    const std::string configured_runtime_dir = adb_cfg_.extras.get("path", "");
    runtime_dir_ = utils::path(configured_runtime_dir);
    if (runtime_dir_.empty()) {
        runtime_dir_ = std::filesystem::current_path() / "runtime" / "scrcpy";
    }
    server_path_ = find_runtime_server(runtime_dir_).value_or(runtime_dir_ / "scrcpy-server");
#ifdef _WIN32
    if (configured_runtime_dir.empty() && !std::filesystem::exists(server_path_)) {
        std::array<wchar_t, MAX_PATH> module_path {};
        if (GetModuleFileNameW(nullptr, module_path.data(), static_cast<DWORD>(module_path.size())) > 0) {
            runtime_dir_ = std::filesystem::path(module_path.data()).parent_path() / "runtime" / "scrcpy";
            server_path_ = find_runtime_server(runtime_dir_).value_or(runtime_dir_ / "scrcpy-server");
        }
    }
#endif
    if (!std::filesystem::exists(server_path_)) {
        LogError << "scrcpy-server not found" << VAR(server_path_);
        return false;
    }

    decoder_ = std::make_unique<FFmpegDecoder>();
    return decoder_->open(runtime_dir_);
}

bool asst::ScrcpyCapture::setup_adb_tunnel()
{
    if (!command_runner_) {
        return false;
    }

    auto port = find_free_port();
    if (!port) {
        LogError << "Failed to find free tcp port for scrcpy";
        return false;
    }
    local_port_ = port.value();

    const auto push_cmd = adb_prefix() + " push " + quote(server_path_) + " /data/local/tmp/scrcpy-server.jar";
    if (!command_runner_(push_cmd, 60000, false)) {
        LogError << "Failed to push scrcpy-server";
        return false;
    }

    command_runner_(adb_prefix() + " forward --remove tcp:" + std::to_string(local_port_), 5000, false);
    const auto forward_cmd =
        adb_prefix() + " forward tcp:" + std::to_string(local_port_) + " localabstract:scrcpy";
    if (!command_runner_(forward_cmd, 10000, false)) {
        LogError << "Failed to setup adb forward for scrcpy";
        return false;
    }
    return true;
}

bool asst::ScrcpyCapture::start_server()
{
    if (!shell_starter_) {
        return false;
    }

    const int video_bit_rate = adb_cfg_.extras.get("video_bit_rate", 25000000);
    const std::string server_cmd = adb_prefix() +
                                   " shell \"CLASSPATH=/data/local/tmp/scrcpy-server.jar app_process / "
                                   "com.genymobile.scrcpy.Server " +
                                   server_version_ +
                                   " tunnel_forward=true audio=false control=false cleanup=true raw_stream=true "
                                   "video_codec=h264 max_fps=60 max_size=0 video_bit_rate=" +
                                   std::to_string(video_bit_rate) + "\"";
    server_handler_ = shell_starter_(server_cmd);
    if (!server_handler_) {
        LogError << "Failed to start scrcpy-server";
        return false;
    }
    return true;
}

bool asst::ScrcpyCapture::start_reader()
{
    stop_requested_ = false;
    reader_running_ = true;
    reader_thread_ = std::thread(&ScrcpyCapture::reader_main, this);

    for (int i = 0; i < 50; ++i) {
        if (stop_requested_) {
            return false;
        }
        if (!reader_running_) {
            LogError << "Scrcpy reader stopped before first frame";
            if (reader_thread_.joinable()) {
                reader_thread_.join();
            }
            return false;
        }
        {
            std::scoped_lock lock(frame_mutex_);
            if (!front_frame_.empty()) {
                return true;
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }

    LogError << "Timed out waiting for first scrcpy frame";
    stop_requested_ = true;
    close_socket();
    if (reader_thread_.joinable()) {
        reader_thread_.join();
    }
    reader_running_ = false;
    return false;
}

void asst::ScrcpyCapture::reader_main()
{
    try {
        tcp::endpoint endpoint(boost::asio::ip::make_address("127.0.0.1"), local_port_);
        {
            std::scoped_lock lock(socket_mutex_);
            if (socket_.is_open()) {
                socket_.close();
            }
            socket_.connect(endpoint);
        }

        std::array<char, 64 * 1024> buffer {};
        while (!stop_requested_) {
            boost::system::error_code ec;
            size_t read = 0;
            read = socket_.read_some(boost::asio::buffer(buffer), ec);
            if (ec) {
                if (!stop_requested_) {
                    LogError << "Scrcpy stream read failed" << ec.message();
                }
                break;
            }
            if (read == 0) {
                continue;
            }

            cv::Mat decoded;
            if (decoder_ && decoder_->decode(std::string_view(buffer.data(), read), decoded) && !decoded.empty()) {
                static bool logged_resolution = false;
                if (!logged_resolution) {
                    LogInfo << "Scrcpy first frame resolution" << VAR(decoded.cols) << VAR(decoded.rows);
                    logged_resolution = true;
                }
                back_frame_ = std::move(decoded);
                {
                    std::scoped_lock lock(frame_mutex_);
                    std::swap(front_frame_, back_frame_);
                    frame_consumed_ = false;
                }
                frame_cv_.notify_one();
            }
        }
    }
    catch (const std::exception& e) {
        if (!stop_requested_) {
            LogError << "Scrcpy reader failed" << e.what();
        }
    }
    close_socket();
    reader_running_ = false;
    frame_cv_.notify_all();
}

void asst::ScrcpyCapture::close_socket()
{
    std::scoped_lock lock(socket_mutex_);
    boost::system::error_code ec;
    if (socket_.is_open()) {
        socket_.shutdown(tcp::socket::shutdown_both, ec);
        socket_.close(ec);
    }
}

std::optional<uint16_t> asst::ScrcpyCapture::find_free_port()
{
    try {
        boost::asio::io_context ctx;
        tcp::acceptor acceptor(ctx, tcp::endpoint(tcp::v4(), 0));
        return acceptor.local_endpoint().port();
    }
    catch (const std::exception& e) {
        LogError << "Failed to allocate local port" << e.what();
        return std::nullopt;
    }
}

std::string asst::ScrcpyCapture::adb_prefix() const
{
    const std::string adb = adb_path_.empty() ? "adb" : quote(utils::path(adb_path_));
    return adb + " -s " + address_;
}

std::string asst::ScrcpyCapture::quote(const std::filesystem::path& path)
{
    return "\"" + utils::path_to_utf8_string(path) + "\"";
}
