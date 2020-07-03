# LnkISAPI-Filter-Loader
ISAPI Filter Loader (Load DLL ISAPI on fly).
Source Daniel "sakura" Wischnewski

##  Description
How does it work?

When you setup the ISAPI Filter for your web site, instead of deploying your ISAPI extension, you will deploy mine. Rename my ISAPI extension so, that it matches the name of your DLL. So, if your DLL is called SomeISAPIExtension.dll, name mine SomeISAPIExtension.dll, too.

Now rename your ISAPI extension to SomeISAPIExtension.upd, short for update. ;-) When the IIS sends the next request to my ISAPI extension, it will look for your update. It will then rename it to SomeISAPIExtension.run and load it into memory and pass all requests along.

When you have another update, copy it as SomeISAPIExtension.upd into the same directory. Within 10 seconds (default, or 500ms debug-mode) my ISAPI extension will look for the update. Finding one, it will unload the current extension and rename it to SomeISAPIExtension.bak, rename yours to SomeISAPIExtension.run and load it. Then, your new version will start to handle all requests. NOTE: This process can take upto one minute. All incoming calls are pooled and passed to the new version as soon as it is loaded.

I created this little tool as an afterthought just now. As it turned out, Egg-Loader is for those extensions and not for filters. I hope you enjoy it, too. There are some things that can be done to enhance it for debugging, and it is not designed for live services!
##  Web Page
http://delphi-notes.blogspot.com/
