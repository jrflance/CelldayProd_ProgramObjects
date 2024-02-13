--liquibase formatted sql

--changeset KarinaMasihHudson:8fbc16f2-b029-4438-9062-be804bb6482c stripComments:false runOnChange:true

CREATE OR ALTER PROC upload.P_TBV_FWA_RMAs
    (@FileID INT = 0)
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        DECLARE
            @Separator VARCHAR(8),
            @TextDelimiter VARCHAR(8) = '"';
        SELECT
            @Separator = ft.Delimiter,
            @TextDelimiter = ft.ROWDelimiter
        FROM upload.tblFileType AS ft
        JOIN upload.tblFile AS f
            ON f.FileTypeID = ft.FileTypeID
        WHERE f.FileID = @FileID;


        TRUNCATE TABLE CellDayTemp.Upload.tblOutPutFile;
        INSERT INTO CellDayTemp.Upload.tblOutPutFile
        (
            Output
        )
        VALUES
        (
            -- noqa: disable=all
            'Account_ID,Act_Order_No,Act_DateOrdered,Act_OrderTotal,Act_Product_ID,Act_Name,IMEI,MIN_MDN,REMOTE_TRANS_ID,Return_Order_No,Return_DateOrdered,Return_OrderTotal'
            -- noqa: enable=all
        );

        DROP TABLE IF EXISTS #tmp;

        CREATE TABLE #tmp
        (
            Account_ID INT,
            Act_Order_No INT,
            Act_DateOrdered DATETIME,
            Act_OrderTotal DECIMAL(9, 2),
            Act_Product_ID INT,
            Act_Name NVARCHAR(255),
            IMEI NVARCHAR(200),
            MIN_MDN NVARCHAR(200),
            REMOTE_TRANS_ID NVARCHAR(200),
            Return_Order_No INT,
            Return_DateOrdered DATETIME,
            Return_OrderTotal DECIMAL(9, 2)
        );

        INSERT INTO #tmp
        (
            Account_ID,
            Act_Order_No,
            Act_DateOrdered,
            Act_OrderTotal,
            Act_Product_ID,
            Act_Name,
            IMEI,
            MIN_MDN,
            REMOTE_TRANS_ID,
            Return_Order_No,
            Return_DateOrdered,
            Return_OrderTotal
        )
        EXEC Tracfone.P_GetFWARMAs 40, NULL, NULL;
        WITH CTEFinal AS (
            SELECT
                CONVERT(
                    VARCHAR(8000),
                    Tracfone.fnEdiRows(
                        @Separator,
                        '',
                        '',
                        Account_ID,
                        Act_Order_No,
                        FORMAT(Act_DateOrdered, 'dd/MM/yyyy hh:mm:ss'),
                        Act_OrderTotal,
                        Act_Product_ID,
                        Act_Name,
                        IMEI,
                        MIN_MDN,
                        REMOTE_TRANS_ID,
                        Return_Order_No,
                        FORMAT(Return_DateOrdered, 'dd/MM/yyyy hh:mm:ss'),
                    -- noqa: disable=all
                    Return_OrderTotal,                    
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT,
                    DEFAULT
                    -- noqa: enable=all
                    )
                ) AS PlainText
            FROM #tmp AS SUB
        )
        INSERT INTO upload.OutPutFile
        (
            Output
        )
        SELECT PlainText
        FROM CTEFinal AS SUB;

        DROP TABLE #tmp;
        DECLARE
            @CNT INT =
            (
                SELECT COUNT(*) FROM CellDayTemp.Upload.tblOutPutFile
            );
        SET @CNT = IIF(@CNT < 2, 2, @CNT);
        SELECT @CNT AS RecordCount;
    END TRY
    BEGIN CATCH
        DECLARE
            @ERRMSG VARCHAR(200) =
            (
                SELECT ERROR_MESSAGE()
            );

        UPDATE f
        SET
            f.FileStatus = -1,
            f.ErrorInfo = @ERRMSG
        FROM upload.tblFile AS f
        WHERE FileID = @FileID

        SELECT 0 AS RecordCount
        ; THROW;
    END CATCH
END;
