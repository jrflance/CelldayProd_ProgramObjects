--liquibase formatted sql

--changeset KarinaMasihHudson:e2f36125-f546-4d28-86e2-e030009cd23b stripComments:false runOnChange:true

/*=============================================
              :
       Author : Karina Masih-Hudson
              :
  Create Date : 2024-01-13
              :
  Description : Script used to get pending FWA RMA home internet orders to send to TF
              :
 SSIS Package : Wrapped in [upload].[P_GetFWARMAs] for
				??\SSISJobsDeployed\Jobs\ETL-GenericUpload.dtsx
			  :
          Job : [ETL - Generic File Upload - Upload.HourlyBetween08:00&20:00]
              :
        Usage : EXEC [Tracfone].[P_GetFWARMAs]  40, NULL, NULL
              :
 =============================================*/

CREATE OR ALTER PROC tracfone.P_GetFWARMAs
    (@TierID INT, @StartDate DATETIME, @EndDate DATETIME)
AS
BEGIN
    BEGIN TRY
        SET TRANSACTION ISOLATION LEVEL READ UNCOMMITTED;
        IF @StartDate IS NULL
            SET @StartDate = CAST(DATEADD(DAY, -1, GETDATE()) AS DATE);
        --SET @StartDate = CONVERT(DATE, DATEADD( DAY, -10, GETDATE()));   --CHANGE THIS

        IF @EndDate IS NULL
            SET @EndDate = CAST(GETDATE() AS DATE);

        IF (@StartDate > @EndDate)
            RAISERROR ('"Start Date:" can not be later than the "End Date:", please re-enter your dates!', 11, 1);

        DROP TABLE IF EXISTS #FWARMA
        SELECT
            orma.ID,
            odrma.Order_No AS [Return_Order_No]
            , odrma.Account_ID
            , odrma.OrderTotal AS [Return_OrderTotal]
            , odrma.DateOrdered AS [Return_DateOrdered]
            , orma.SKU
            , orma.Name
            , CAST(odrma.AuthNumber AS INT) AS [AuthNumberINT]
        INTO #FWARMA
        FROM dbo.Orders AS orma
        JOIN dbo.Order_No AS odrma
            ON odrma.Order_No = orma.Order_No
        JOIN Account.tblProgramTierProducts AS ptp
            ON
                ptp.ProductID = orma.Product_ID
                AND ptp.TierID = @TierID
        JOIN dbo.Products AS p
            ON
                p.Product_ID = orma.Product_ID
                AND p.SubProductTypeId = 17			--home internet
        WHERE
            odrma.OrderType_ID IN (74, 75)			--Prepaid Activation Refund, Postpaid Activation Refund
            AND odrma.OrderTotal < 0
            AND odrma.DateFilled >= @StartDate
            AND odrma.DateFilled < @EndDate
            AND odrma.Filled = 0
            AND odrma.Void = 0
            AND ISNULL(orma.ParentItemID, 0) IN (0, 1);

        DROP TABLE IF EXISTS #Activations
        SELECT
            od.Account_ID AS [Account_ID]
            , o.ID AS [Act_Order_ID]
            , od.Order_No AS [Act_Order_No]
            , od.DateOrdered AS [Act_DateOrdered]
            , od.OrderTotal AS [Act_OrderTotal]
            , o.Product_ID AS [Act_Product_ID]
            , o.Name AS [Act_Name]
            , odrma.Return_Order_No
            , odrma.Return_DateOrdered
            , odrma.Return_OrderTotal
        INTO #Activations
        FROM #FWARMA AS odrma
        JOIN cellday_prod.dbo.Order_No AS od
            ON
                od.Order_No = odrma.AuthNumberINT
                AND odrma.Return_OrderTotal = (od.OrderTotal * -1)
        JOIN cellday_prod.dbo.orders AS o
            ON od.Order_No = o.Order_No
        WHERE
            od.OrderType_ID IN (22, 23)
            AND ISNULL(o.ParentItemID, 0) IN (0, 1);

        DROP TABLE IF EXISTS #IMEI
        SELECT
            A.OrderID
            , B.Act_Order_No
            , A.AddonsID
            , A.AddonsValue AS [IMEI]
        INTO #IMEI
        FROM #Activations AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.Act_Order_ID = A.OrderID
        JOIN dbo.tblAddonFamily AS f2
            ON
                f2.AddonID = A.AddonsID
                AND f2.AddonTypeName IN ('DeviceType', 'DeviceBYOPType');

        DROP TABLE IF EXISTS #MDN
        SELECT
            A.OrderID
            , A.AddonsID
            , A.AddonsValue AS MIN_MDN
        INTO #MDN
        FROM #Activations AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.Act_Order_ID = A.OrderID
        JOIN dbo.tblAddonFamily AS f2
            ON
                f2.AddonID = A.AddonsID
                AND f2.AddonTypeName IN ('PhoneNumberType');


        DROP TABLE IF EXISTS #Transaction
        SELECT
            A.OrderID
            , A.AddonsID
            , A.AddonsValue AS REMOTE_TRANS_ID
        INTO #Transaction
        FROM #Activations AS B
        JOIN dbo.tblOrderItemAddons AS A
            ON B.Act_Order_ID = A.OrderID
        WHERE A.AddonsID = 206;


        DROP TABLE IF EXISTS #HandsetRMA
        SELECT
            i.Act_Order_No
            , o.ID AS [Handset_RMA_ID]
            , od.Order_No AS [Handset_RMA_OrderNo]
            , od.OrderType_ID
            , od.Filled
            , od.Void
            , o.Name
        INTO #HandsetRMA
        FROM #IMEI AS i
        JOIN dbo.Orders AS o
            ON i.IMEI = o.SKU
        JOIN dbo.Order_No AS od
            ON od.Order_No = o.Order_No
        WHERE od.OrderType_ID IN (61, 62);


        SELECT
            a.Account_ID
            , a.Act_Order_No
            , a.Act_DateOrdered
            , a.Act_OrderTotal
            , a.Act_Product_ID
            , a.Act_Name
            , imei.IMEI
            , mdn.MIN_MDN
            , tr.REMOTE_TRANS_ID
            , a.Return_Order_No
            , a.Return_DateOrdered
            , a.Return_OrderTotal
        FROM #Activations AS a
        LEFT JOIN #IMEI AS imei
            ON imei.OrderID = a.Act_Order_ID
        LEFT JOIN #MDN AS mdn
            ON mdn.OrderID = a.Act_Order_ID
        LEFT JOIN #Transaction AS tr
            ON tr.OrderID = a.Act_Order_ID
        WHERE EXISTS (SELECT 1 FROM #HandsetRMA AS r WHERE r.Act_Order_No = a.Act_Order_No AND r.Filled = 1)
        ORDER BY a.Act_Order_No

        DROP TABLE IF EXISTS #HandsetRMAErrors

        SELECT *
        INTO #HandsetRMAErrors
        FROM (
            SELECT
                a.Account_ID
                , a.Act_Order_No
                , a.Act_DateOrdered
                , a.Act_OrderTotal
                , a.Act_Product_ID
                , a.Act_Name
                , imei.IMEI
                , mdn.MIN_MDN
                , tr.REMOTE_TRANS_ID
                , a.Return_Order_No
                , a.Return_DateOrdered
                , a.Return_OrderTotal
                , NULL AS [Handset_RMA_ID]
                , NULL AS [Handset_RMA_OrderNo]
                , IIF(
                    pak.Activation_Type LIKE 'byop', 'Activated as BYOP; Handset RMA not found', 'Handset RMA not found'
                ) AS [Error]
            FROM #Activations AS a
            JOIN #IMEI AS imei
                ON imei.OrderID = a.Act_Order_ID
            JOIN dbo.Phone_Active_Kit AS pak
                ON
                    pak.order_no = a.Act_Order_No
                    AND pak.Sim_ID = imei.IMEI
            LEFT JOIN #MDN AS mdn
                ON mdn.OrderID = a.Act_Order_ID
            LEFT JOIN #Transaction AS tr
                ON tr.OrderID = a.Act_Order_ID
            WHERE NOT EXISTS (SELECT 1 FROM #HandsetRMA AS r WHERE r.Act_Order_No = a.Act_Order_No)
            UNION
            SELECT
                a.Account_ID
                , a.Act_Order_No
                , a.Act_DateOrdered
                , a.Act_OrderTotal
                , a.Act_Product_ID
                , a.Act_Name
                , imei.IMEI
                , mdn.MIN_MDN
                , tr.REMOTE_TRANS_ID
                , a.Return_Order_No
                , a.Return_DateOrdered
                , a.Return_OrderTotal
                , r.Handset_RMA_ID
                , r.Handset_RMA_OrderNo
                , 'Handset RMA is voided' AS [Error]
            FROM #Activations AS a
            JOIN #IMEI AS imei
                ON imei.OrderID = a.Act_Order_ID
            LEFT JOIN #MDN AS mdn
                ON mdn.OrderID = a.Act_Order_ID
            LEFT JOIN #Transaction AS tr
                ON tr.OrderID = a.Act_Order_ID
            JOIN #HandsetRMA AS r
                ON r.Act_Order_No = a.Act_Order_No AND r.Void = 1
        ) AS d;
    END TRY
    BEGIN CATCH
    ; THROW
    END CATCH
    BEGIN TRY
        IF EXISTS (SELECT 1 FROM #HandsetRMAErrors)
            BEGIN
                DECLARE @Server VARCHAR(100) = (SELECT CAST(SERVERPROPERTY('Servername') AS VARCHAR(100)))

                DECLARE
                    @TestWarning VARCHAR(30)
                    = (CASE WHEN @Server IN ('DB01', 'DB03') THEN '' ELSE 'TEST TEST TEST; ' END)
                    , @Recipient VARCHAR(100)
                    = (CASE WHEN @Server IN ('DB01', 'DB03') THEN 'khudson@tcetra.com' ELSE 'khudson@tcetra.com' END)
                DECLARE
                    @str_profile_name VARCHAR(100) = 'SQLAlerts'
                    , @str_from_address VARCHAR(100) = 'SqlAlerts@tcetra.com'
                    --(SELECT ft.EmailRecipients FROM upload.tblFileType AS ft WHERE ft.FileTypeID = @FileTypeID),
                    , @str_recipients VARCHAR(100) = @Recipient
                    , @str_subject VARCHAR(100) = ('Notification: Handset RMA Missing for FWA RMA Order')
                    , @xml NVARCHAR(MAX) = CAST(
                        -- noqa: disable=all
                        (
                            SELECT
                                d.Account_ID AS 'td', ''
                                , d.Act_Order_No AS 'td', ''
                                , d.Act_DateOrdered AS 'td', ''
                                , d.Act_OrderTotal AS 'td', ''
                                , d.Act_Product_ID AS 'td', ''
                                , d.Act_Name AS 'td', ''
                                , d.IMEI AS 'td', ''
                                , d.MIN_MDN AS 'td', ''
                                , d.REMOTE_TRANS_ID AS 'td', ''
                                , d.Return_Order_No AS 'td', ''
                                , d.Return_DateOrdered AS 'td', ''
                                , d.Return_OrderTotal AS 'td', ''
                                , d.Handset_RMA_ID AS 'td', ''
                                , d.Handset_RMA_OrderNo AS 'td', ''
                                , d.Error AS 'td', ''
                            FROM #HandsetRMAErrors AS d
                            ORDER BY d.Return_Order_No
                            FOR XML PATH ('tr'), ELEMENTS
                        ) AS VARCHAR(MAX)
                    )
                    -- noqa: enable=all
                    , @str_body NVARCHAR(MAX) = N'<html><body>
				<H3>Handset RMA is missing for FWA RMA Orders. Please see the table below for order details. The following did not get sent.</H3>
				<table border = 1>
				<tr>
					<th>Account_ID</th>
					<th>Act_Order_No</th>
					<th>Act_DateOrdered</th>
					<th>Act_OrderTotal</th>
					<th>Act_Product_ID</th>
					<th>Act_Name</th>
					<th>IMEI</th>
					<th>MIN_MDN</th>
					<th>REMOTE_TRANS_ID</th>
					<th>Return_Order_No</th>
					<th>Return_DateOrdered</th>
					<th>Return_OrderTotal</th>
					<th>Handset_RMA_ID</th>
					<th>Handset_RMA_OrderNo</th>
					<th>Error</th>
				</tr>';
                SET @str_body = @str_body + @xml + N'</table></body></html>';
                EXEC [msdb].[dbo].[sp_send_dbmail]
                    @profile_name = @str_profile_name,
                    @from_address = @str_from_address,
                    @recipients = @str_recipients,
                    @subject = @str_subject,
                    @body = @str_body,
                    @body_format = 'HTML';
            END
    END TRY
    BEGIN CATCH
        RETURN -1
    END CATCH
END
