#include <string>
#include <fstream>
#include <filesystem>
#include <sys/stat.h>

#include "utils/string.h"

namespace
{
bool isWithinRoot(const std::filesystem::path &root, const std::filesystem::path &candidate)
{
    const auto relative = candidate.lexically_relative(root);
    if(relative.empty() || relative.is_absolute())
        return false;
    const auto first = relative.begin();
    return first == relative.end() || *first != "..";
}
}

bool isInScope(const std::string &path)
{
    try
    {
        const auto root = std::filesystem::weakly_canonical(std::filesystem::current_path());
        const auto candidate = std::filesystem::weakly_canonical(std::filesystem::path(path));
        return isWithinRoot(root, candidate);
    }
    catch(const std::filesystem::filesystem_error &)
    {
        return false;
    }
}

// TODO: Add preprocessor option to disable (open web service safety)
std::string fileGet(const std::string &path, bool scope_limit)
{
    std::string content;

    if(scope_limit && !isInScope(path))
        return "";

    std::FILE *fp = std::fopen(path.c_str(), "rb");
    if(fp)
    {
        std::fseek(fp, 0, SEEK_END);
        long tot = std::ftell(fp);
        /*
        char *data = new char[tot + 1];
        data[tot] = '\0';
        std::rewind(fp);
        std::fread(&data[0], 1, tot, fp);
        std::fclose(fp);
        content.assign(data, tot);
        delete[] data;
        */
        content.resize(tot);
        std::rewind(fp);
        std::fread(&content[0], 1, tot, fp);
        std::fclose(fp);
    }

    /*
    std::stringstream sstream;
    std::ifstream infile;
    infile.open(path, std::ios::binary);
    if(infile)
    {
        sstream<<infile.rdbuf();
        infile.close();
        content = sstream.str();
    }
    */
    return content;
}

bool fileExist(const std::string &path, bool scope_limit)
{
    //using c++17 standard, but may cause problem on clang
    //return std::filesystem::exists(path);
    if(scope_limit && !isInScope(path))
        return false;
    struct stat st;
    return stat(path.data(), &st) == 0 && S_ISREG(st.st_mode);
}

bool fileCopy(const std::string &source, const std::string &dest)
{
    std::ifstream infile;
    std::ofstream outfile;
    infile.open(source, std::ios::binary);
    if(!infile)
        return false;
    outfile.open(dest, std::ios::binary);
    if(!outfile)
        return false;
    try
    {
        outfile<<infile.rdbuf();
    }
    catch (std::exception &e)
    {
        return false;
    }
    infile.close();
    outfile.close();
    return true;
}

int fileWrite(const std::string &path, const std::string &content, bool overwrite)
{
    /*
    std::fstream outfile;
    std::ios_base::openmode mode = overwrite ? std::ios_base::out : std::ios_base::app;
    mode |= std::ios_base::binary;
    outfile.open(path, mode);
    outfile << content;
    outfile.close();
    return 0;
    */
    const char *mode = overwrite ? "wb" : "ab";
    std::FILE *fp = std::fopen(path.c_str(), mode);
    if(fp == nullptr)
        return -1;
    std::fwrite(content.c_str(), 1, content.size(), fp);
    std::fclose(fp);
    return 0;
}
