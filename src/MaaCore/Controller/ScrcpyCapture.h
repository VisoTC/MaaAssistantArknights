#pragma once

#include <atomic>
#include <condition_variable>
#include <filesystem>
#include <functional>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <thread>

#include <boost/asio/io_context.hpp>
#include <boost/asio/ip/tcp.hpp>

#include "Config/GeneralConfig.h"
#include "MaaUtils/NoWarningCVMat.hpp"

namespace asst
{
class ScrcpyCapture
{
public:
    using CommandRunner = std::function<std::optional<std::string>(const std::string&, int64_t, bool)>;
    using ShellStarter = std::function<std::shared_ptr<class IOHandler>(const std::string&)>;

    ScrcpyCapture();
    ~ScrcpyCapture();

    bool inited() const { return inited_; }

    bool init(
        const AdbCfg& adb_cfg,
        const std::string& adb_path,
        const std::string& address,
        CommandRunner command_runner,
        ShellStarter shell_starter);
    bool reload();
    void uninit();

    std::optional<cv::Mat> screencap();

private:
    class FFmpegDecoder;

    bool init_runtime();
    bool setup_adb_tunnel();
    bool start_server();
    bool start_reader();
    void reader_main();
    void close_socket();
    std::optional<uint16_t> find_free_port();

    std::string adb_prefix() const;
    static std::string quote(const std::filesystem::path& path);

private:
    AdbCfg adb_cfg_;
    std::string adb_path_;
    std::string address_;
    CommandRunner command_runner_;
    ShellStarter shell_starter_;

    std::filesystem::path runtime_dir_;
    std::filesystem::path server_path_;
    std::string server_version_;
    uint16_t local_port_ = 0;

    std::shared_ptr<IOHandler> server_handler_;
    std::unique_ptr<FFmpegDecoder> decoder_;

    boost::asio::io_context io_context_;
    boost::asio::ip::tcp::socket socket_;
    mutable std::mutex socket_mutex_;

    std::thread reader_thread_;
    std::atomic_bool stop_requested_ = false;
    std::atomic_bool reader_running_ = false;
    bool inited_ = false;

    mutable std::mutex frame_mutex_;
    std::condition_variable frame_cv_;
    cv::Mat front_frame_;
    cv::Mat back_frame_;
    bool frame_consumed_ = true;
};
} // namespace asst
